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

package signerverifier

import (
	"bytes"
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/sigstore/sigstore/pkg/signature/kms"

	rekorsv "github.com/sigstore/rekor-tiles/v2/internal/signerverifier"

	// fakekms provides an in-memory KMS provider so that the KMS branch of New
	// can be exercised without cloud credentials.
	_ "github.com/sigstore/sigstore/pkg/signature/kms/fake"
)

// azureKMSScheme is the reference scheme registered by the Azure KMS provider. It
// is written literally rather than imported so that this package's own blank
// import is what registers it.
const azureKMSScheme = "azurekms://"

// writeTestKey generates an unencrypted ECDSA private key and returns its path.
func writeTestKey(t *testing.T) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}
	der, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatalf("marshaling key: %v", err)
	}
	keyPath := filepath.Join(t.TempDir(), "ec-key.pem")
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der}), 0600); err != nil {
		t.Fatalf("writing key: %v", err)
	}
	return keyPath
}

// writeTestEd25519Key generates an unencrypted ed25519 private key and returns its
// path.
func writeTestEd25519Key(t *testing.T) string {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		t.Fatalf("marshaling key: %v", err)
	}
	keyPath := filepath.Join(t.TempDir(), "ed25519-key.pem")
	if err := os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0600); err != nil {
		t.Fatalf("writing key: %v", err)
	}
	return keyPath
}

// TestNewWithEd25519File guards the file signer against the Azure key-type check,
// which must apply to the KMS path only. ed25519 is unusable in Key Vault but is
// the only key type compatible with witnessing, so it has to keep working when
// signing from a key file.
func TestNewWithEd25519File(t *testing.T) {
	keyPath := writeTestEd25519Key(t)
	sv, err := New(context.Background(), WithFile(keyPath, ""))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	msg := []byte("rekor")
	sig, err := sv.SignMessage(bytes.NewReader(msg))
	if err != nil {
		t.Fatalf("signing message: %v", err)
	}
	if err := sv.VerifySignature(bytes.NewReader(sig), bytes.NewReader(msg)); err != nil {
		t.Fatalf("verifying signature: %v", err)
	}
}

func TestNewWithFile(t *testing.T) {
	keyPath := writeTestKey(t)
	sv, err := New(context.Background(), WithFile(keyPath, ""))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	msg := []byte("rekor")
	sig, err := sv.SignMessage(bytes.NewReader(msg))
	if err != nil {
		t.Fatalf("signing message: %v", err)
	}
	if err := sv.VerifySignature(bytes.NewReader(sig), bytes.NewReader(msg)); err != nil {
		t.Fatalf("verifying signature: %v", err)
	}
}

func TestNewWithKMS(t *testing.T) {
	sv, err := New(context.Background(), WithKMS("fakekms://key"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	msg := []byte("rekor")
	sig, err := sv.SignMessage(bytes.NewReader(msg))
	if err != nil {
		t.Fatalf("signing message: %v", err)
	}
	if err := sv.VerifySignature(bytes.NewReader(sig), bytes.NewReader(msg)); err != nil {
		t.Fatalf("verifying signature: %v", err)
	}
}

// TestAzureKMSProviderRegistered guards against the blank import of the Azure KMS
// provider being dropped, which would silently disable azurekms:// keys.
func TestAzureKMSProviderRegistered(t *testing.T) {
	if !slices.Contains(kms.SupportedProviders(), azureKMSScheme) {
		t.Errorf("expected %s to be a supported KMS provider, got %v", azureKMSScheme, kms.SupportedProviders())
	}
}

// TestOnlyAzureKMSProviderLinked asserts that no other cloud provider's KMS is
// pulled into this package, which is the whole point of having per-cloud
// signerverifier packages. fakekms is expected, because this test file imports
// it.
func TestOnlyAzureKMSProviderLinked(t *testing.T) {
	for _, unwanted := range []string{"gcpkms://", "awskms://", "hashivault://"} {
		if slices.Contains(kms.SupportedProviders(), unwanted) {
			t.Errorf("unexpected KMS provider %s linked into the azure package, got %v", unwanted, kms.SupportedProviders())
		}
	}
}

// TestKMSTakesPrecedenceOverFile documents that the KMS branch is evaluated
// before the file branch, matching the gcp and aws packages.
func TestKMSTakesPrecedenceOverFile(t *testing.T) {
	keyPath := writeTestKey(t)
	sv, err := New(context.Background(), WithKMS("fakekms://key"), WithFile(keyPath, ""))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// The fake KMS signer reports a fixed SHA-256 hash, as a file signer would,
	// so assert on the concrete type instead.
	if _, ok := sv.(*rekorsv.File); ok {
		t.Errorf("expected the KMS signer to take precedence, got a file signer")
	}
}

func TestNewErrors(t *testing.T) {
	tests := []struct {
		name    string
		opts    []Option
		wantErr string
	}{
		{
			name:    "no options",
			opts:    nil,
			wantErr: "insufficient signing parameters provided",
		},
		{
			name:    "missing key file",
			opts:    []Option{WithFile(filepath.Join(t.TempDir(), "missing.pem"), "")},
			wantErr: "failed to read key file",
		},
		{
			name:    "tink is not supported",
			opts:    []Option{WithTink("azure-kms://kek", "keyset.json.enc")},
			wantErr: "tink is not supported for Azure Key Vault",
		},
		{
			name:    "tink with a gcp KEK is also not supported",
			opts:    []Option{WithTink("gcp-kms://kek", "keyset.json.enc")},
			wantErr: "tink is not supported for Azure Key Vault",
		},
		{
			name:    "unregistered KMS scheme",
			opts:    []Option{WithKMS("unsupportedkms://key")},
			wantErr: "insufficient signing parameters provided",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sv, err := New(context.Background(), tt.opts...)
			if err == nil {
				t.Fatalf("expected error, got signer-verifier %v", sv)
			}
			if !strings.Contains(err.Error(), tt.wantErr) {
				t.Errorf("expected error containing %q, got %q", tt.wantErr, err.Error())
			}
		})
	}
}

// TestWithKMSTakesOnlyAURI is a compile-time guard: Azure derives the digest from
// the Key Vault key, so no hash may be threaded through WithKMS. If a second
// parameter is ever added, this stops compiling.
func TestWithKMSTakesOnlyAURI(t *testing.T) {
	opt := WithKMS("azurekms://vault.vault.azure.net/key")
	if opt == nil {
		t.Fatal("expected WithKMS to return an option")
	}
	sc := &signerVerifierConfig{}
	opt(sc)
	if sc.kms != "azurekms://vault.vault.azure.net/key" {
		t.Errorf("expected the KMS URI to be set, got %q", sc.kms)
	}
}

// rsaPublicKeyOfBits returns an RSA public key whose modulus has the given bit
// length. Only the modulus size matters to checkSupportedAzureKey, so this avoids
// generating real (and, at 4096 bits, slow) keys.
func rsaPublicKeyOfBits(bits int) *rsa.PublicKey {
	return &rsa.PublicKey{
		N: new(big.Int).Lsh(big.NewInt(1), uint(bits-1)),
		E: 65537,
	}
}

// TestCheckSupportedAzureKey pins the key types the Azure Key Vault provider can
// actually sign with, so that an unusable key is rejected at startup rather than
// when the first checkpoint is signed.
func TestCheckSupportedAzureKey(t *testing.T) {
	tests := []struct {
		name    string
		key     func(t *testing.T) crypto.PublicKey
		wantErr string
	}{
		{
			name: "EC P-256",
			key:  func(t *testing.T) crypto.PublicKey { return ecdsaPublicKey(t, elliptic.P256()) },
		},
		{
			name: "EC P-384",
			key:  func(t *testing.T) crypto.PublicKey { return ecdsaPublicKey(t, elliptic.P384()) },
		},
		{
			name: "EC P-521",
			key:  func(t *testing.T) crypto.PublicKey { return ecdsaPublicKey(t, elliptic.P521()) },
		},
		{
			name: "RSA 2048",
			key:  func(_ *testing.T) crypto.PublicKey { return rsaPublicKeyOfBits(2048) },
		},
		{
			name: "RSA 3072",
			key:  func(_ *testing.T) crypto.PublicKey { return rsaPublicKeyOfBits(3072) },
		},
		{
			name: "RSA 4096",
			key:  func(_ *testing.T) crypto.PublicKey { return rsaPublicKeyOfBits(4096) },
		},
		{
			name:    "unsupported EC curve",
			key:     func(t *testing.T) crypto.PublicKey { return ecdsaPublicKey(t, elliptic.P224()) },
			wantErr: "unsupported EC curve",
		},
		{
			name:    "RSA 1024",
			key:     func(_ *testing.T) crypto.PublicKey { return rsaPublicKeyOfBits(1024) },
			wantErr: "unsupported RSA key size 1024 bits",
		},
		{
			name: "ed25519",
			key: func(t *testing.T) crypto.PublicKey {
				pub, _, err := ed25519.GenerateKey(rand.Reader)
				if err != nil {
					t.Fatalf("generating ed25519 key: %v", err)
				}
				return pub
			},
			wantErr: "unsupported key type",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := checkSupportedAzureKey(tt.key(t))
			if tt.wantErr == "" {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tt.wantErr)
			}
			if !strings.Contains(err.Error(), tt.wantErr) {
				t.Errorf("expected error containing %q, got %q", tt.wantErr, err.Error())
			}
		})
	}
}

func ecdsaPublicKey(t *testing.T, curve elliptic.Curve) *ecdsa.PublicKey {
	t.Helper()
	key, err := ecdsa.GenerateKey(curve, rand.Reader)
	if err != nil {
		t.Fatalf("generating ecdsa key on %s: %v", curve.Params().Name, err)
	}
	return &key.PublicKey
}
