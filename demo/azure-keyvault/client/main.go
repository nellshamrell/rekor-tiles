//
// Copyright 2026 The Sigstore Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Command demo-client submits an entry to a running rekor-tiles server and
// verifies the resulting checkpoint signature against a public key on disk.
//
// It's written for the Azure Key Vault demo, where the public key is exported
// from Key Vault with `az keyvault key download`. Verifying against that key
// proves the checkpoint really was signed by the Key Vault key, independently
// of anything the server reports about itself.
package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	v1 "github.com/sigstore/protobuf-specs/gen/pb-go/common/v1"
	"github.com/sigstore/rekor-tiles/v2/pkg/client/write"
	pb "github.com/sigstore/rekor-tiles/v2/pkg/generated/protobuf"
	"github.com/sigstore/rekor-tiles/v2/pkg/note"
	"github.com/sigstore/sigstore/pkg/cryptoutils"
	"github.com/sigstore/sigstore/pkg/signature"
	signednote "golang.org/x/mod/sumdb/note"
)

func main() {
	serverURL := flag.String("url", "http://localhost:3000", "rekor server base URL (the write path)")
	tilesURL := flag.String("tiles-url", "http://localhost:8000", "base URL of the static file server serving the POSIX storage directory")
	pubKeyPath := flag.String("pubkey", "", "path to the log's public key in PEM form (required)")
	origin := flag.String("origin", "rekor-azure-demo", "log origin, must match the server's --hostname")
	submit := flag.Bool("submit", true, "submit a new entry before verifying")
	flag.Parse()

	if *pubKeyPath == "" {
		exit("--pubkey is required")
	}

	verifier, err := noteVerifier(*pubKeyPath, *origin)
	if err != nil {
		exit("building verifier: %v", err)
	}

	step("Fetching the current checkpoint")
	before, beforeSize, err := checkpoint(*tilesURL, verifier)
	if err != nil {
		exit("%v", err)
	}
	fmt.Printf("%s\n", indent(before))
	okf("Signature verified against %s", *pubKeyPath)
	okf("Tree size: %d", beforeSize)

	if !*submit {
		return
	}

	step("Submitting a hashedrekord entry")
	if err := submitEntry(*serverURL); err != nil {
		exit("submitting entry: %v", err)
	}
	okf("Entry accepted")

	step("Waiting for a new checkpoint to be published")
	after, afterSize, err := waitForGrowth(*tilesURL, verifier, beforeSize, 30*time.Second)
	if err != nil {
		exit("%v", err)
	}
	fmt.Printf("%s\n", indent(after))
	okf("Signature verified against %s", *pubKeyPath)
	okf("Tree size grew: %d -> %d", beforeSize, afterSize)

	step("Result")
	fmt.Println("    The log advanced and every checkpoint above carries a valid")
	fmt.Println("    signature made by the Azure Key Vault key. The private key never")
	fmt.Println("    left the vault; tiles are on the local filesystem via the POSIX driver.")
}

// noteVerifier builds a signed-note verifier from a PEM public key. The origin
// is part of the key hash, so it has to match the server's --hostname.
func noteVerifier(pubKeyPath, origin string) (signednote.Verifier, error) {
	pemBytes, err := os.ReadFile(pubKeyPath)
	if err != nil {
		return nil, fmt.Errorf("reading public key: %w", err)
	}
	pubKey, err := cryptoutils.UnmarshalPEMToPublicKey(pemBytes)
	if err != nil {
		return nil, fmt.Errorf("parsing public key: %w", err)
	}
	sv, err := signature.LoadDefaultVerifier(pubKey)
	if err != nil {
		return nil, fmt.Errorf("loading verifier: %w", err)
	}
	return note.NewNoteVerifier(origin, sv)
}

// checkpoint fetches the checkpoint and verifies its signature, returning the
// note text and the tree size.
func checkpoint(tilesURL string, verifier signednote.Verifier) (string, uint64, error) {
	resp, err := http.Get(tilesURL + "/checkpoint") //nolint:gosec,noctx // demo client, URL is operator-supplied
	if err != nil {
		return "", 0, fmt.Errorf("fetching checkpoint: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", 0, fmt.Errorf("fetching checkpoint: unexpected status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", 0, fmt.Errorf("reading checkpoint: %w", err)
	}

	// note.Open fails unless the signature verifies under the given key, so
	// this is the actual proof that Key Vault signed the checkpoint.
	n, err := signednote.Open(body, signednote.VerifierList(verifier))
	if err != nil {
		return "", 0, fmt.Errorf("verifying checkpoint signature: %w", err)
	}

	size, err := treeSize(n.Text)
	if err != nil {
		return "", 0, err
	}
	return string(body), size, nil
}

// treeSize pulls the size out of a checkpoint note, whose second line is the
// tree size per the tlog-checkpoint spec.
func treeSize(text string) (uint64, error) {
	lines := strings.Split(strings.TrimSpace(text), "\n")
	if len(lines) < 2 {
		return 0, fmt.Errorf("malformed checkpoint: %q", text)
	}
	size, err := strconv.ParseUint(strings.TrimSpace(lines[1]), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("parsing tree size from %q: %w", lines[1], err)
	}
	return size, nil
}

// waitForGrowth polls until the verified tree size exceeds was, or times out.
func waitForGrowth(tilesURL string, verifier signednote.Verifier, was uint64, timeout time.Duration) (string, uint64, error) {
	deadline := time.Now().Add(timeout)
	for {
		body, size, err := checkpoint(tilesURL, verifier)
		if err == nil && size > was {
			return body, size, nil
		}
		if time.Now().After(deadline) {
			if err != nil {
				return "", 0, fmt.Errorf("waiting for a new checkpoint: %w", err)
			}
			return "", 0, fmt.Errorf("tree size stayed at %d after %s", size, timeout)
		}
		time.Sleep(time.Second)
	}
}

// submitEntry writes a hashedrekord entry signed by a throwaway client key.
// This is ordinary client traffic; it has nothing to do with Key Vault, which
// signs checkpoints rather than entries.
func submitEntry(serverURL string) error {
	writer, err := write.NewWriter(serverURL)
	if err != nil {
		return fmt.Errorf("creating writer: %w", err)
	}

	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return fmt.Errorf("generating client key: %w", err)
	}
	pubKey, err := x509.MarshalPKIXPublicKey(privKey.Public())
	if err != nil {
		return fmt.Errorf("marshaling client key: %w", err)
	}

	// A unique artifact per run, so repeated runs aren't rejected as duplicates.
	artifact := fmt.Sprintf("azure-keyvault-demo-%d", time.Now().UnixNano())
	digest := sha256.Sum256([]byte(artifact))
	sig, err := ecdsa.SignASN1(rand.Reader, privKey, digest[:])
	if err != nil {
		return fmt.Errorf("signing artifact: %w", err)
	}

	entry := &pb.HashedRekordRequestV002{
		Signature: &pb.Signature{
			Content: sig,
			Verifier: &pb.Verifier{
				Verifier: &pb.Verifier_PublicKey{
					PublicKey: &pb.PublicKey{RawBytes: pubKey},
				},
				KeyDetails: v1.PublicKeyDetails_PKIX_ECDSA_P256_SHA_256,
			},
		},
		Digest: digest[:],
	}

	tle, err := writer.Add(context.Background(), entry)
	if err != nil {
		return err
	}
	fmt.Printf("    artifact:  %s\n", artifact)
	fmt.Printf("    log index: %d\n", tle.GetLogIndex())
	return nil
}

func step(format string, a ...any) {
	fmt.Printf("\n\033[1;34m==> %s\033[0m\n", fmt.Sprintf(format, a...))
}

func okf(format string, a ...any) {
	fmt.Printf("    \033[1;32mOK\033[0m %s\n", fmt.Sprintf(format, a...))
}

func indent(s string) string {
	var b strings.Builder
	for _, line := range strings.Split(strings.TrimRight(s, "\n"), "\n") {
		b.WriteString("    | " + line + "\n")
	}
	return strings.TrimRight(b.String(), "\n")
}

func exit(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "\n\033[1;31mERROR: %s\033[0m\n", fmt.Sprintf(format, a...))
	os.Exit(1)
}
