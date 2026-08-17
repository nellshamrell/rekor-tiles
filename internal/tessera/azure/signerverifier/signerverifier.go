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

// Package signerverifier provides checkpoint signer-verifiers backed by Azure
// Key Vault (azurekms://) or by a private key file on disk.
//
// Following the same approach as the gcp and aws packages in this repository,
// only the Azure KMS provider is linked here, so that binaries using this
// package don't pull in every cloud provider's SDK.
package signerverifier

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"fmt"
	"slices"
	"strings"

	sv "github.com/sigstore/rekor-tiles/v2/internal/signerverifier"
	"github.com/sigstore/sigstore/pkg/signature"
	"github.com/sigstore/sigstore/pkg/signature/kms"

	// this is imported to load the provider via its init() call
	_ "github.com/sigstore/sigstore/pkg/signature/kms/azure"
)

// New returns a SignerVerifier for Azure Key Vault or a private key file on disk.
func New(ctx context.Context, opts ...Option) (signature.SignerVerifier, error) {
	sc := &signerVerifierConfig{}
	for _, o := range opts {
		o(sc)
	}
	switch {
	case slices.ContainsFunc(kms.SupportedProviders(),
		func(s string) bool {
			return strings.HasPrefix(sc.kms, s)
		}):
		// Azure Key Vault derives the digest algorithm from the key itself, so no
		// hash is supplied here. See WithKMS.
		kmsSV, err := kms.Get(ctx, sc.kms, crypto.Hash(0))
		if err != nil {
			return nil, err
		}
		pub, err := kmsSV.PublicKey()
		if err != nil {
			return nil, fmt.Errorf("failed to read the public key for %q: %w; note that Key Vault key types other than EC P-256, P-384, P-521 and RSA-2048, RSA-3072, RSA-4096 are not supported, including P-256K (secp256k1)", sc.kms, err)
		}
		if err := checkSupportedAzureKey(pub); err != nil {
			return nil, fmt.Errorf("unusable signing key %q: %w", sc.kms, err)
		}
		return kmsSV, nil
	case sc.tinkKEKURI != "":
		return nil, fmt.Errorf("tink is not supported for Azure Key Vault; use a KMS or file signer-verifier instead")
	case sc.filePath != "":
		return sv.NewFileSignerVerifier(sc.filePath, sc.password)
	default:
		return nil, fmt.Errorf("insufficient signing parameters provided, must configure one of file or KMS signer-verifiers")
	}
}

// checkSupportedAzureKey rejects public keys that the Azure Key Vault provider cannot
// sign with, so that a misconfigured key fails at startup rather than when the first
// checkpoint is signed.
//
// This mirrors getKeyVaultHashFunc in sigstore's kms/azure provider, which selects the
// digest and signature algorithm from the key: EC P-256/P-384/P-521 (ES256/384/512) and
// RSA moduli of 256/384/512 bytes, i.e. RSA-2048/3072/4096 (RS256/384/512). Note that
// most unsupported Key Vault key types, including P-256K (secp256k1), are already
// rejected earlier while decoding the key's JWK; this is a backstop for keys that decode
// but still can't be used.
func checkSupportedAzureKey(pub crypto.PublicKey) error {
	switch key := pub.(type) {
	case *ecdsa.PublicKey:
		switch key.Curve {
		case elliptic.P256(), elliptic.P384(), elliptic.P521():
			return nil
		default:
			return fmt.Errorf("unsupported EC curve %q, must be one of P-256, P-384, P-521", key.Params().Name)
		}
	case *rsa.PublicKey:
		// Size reports the modulus size in bytes.
		switch key.Size() {
		case 256, 384, 512:
			return nil
		default:
			return fmt.Errorf("unsupported RSA key size %d bits, must be one of 2048, 3072, 4096", key.N.BitLen())
		}
	default:
		return fmt.Errorf("unsupported key type %T, must be ECDSA or RSA", pub)
	}
}

type signerVerifierConfig struct {
	filePath   string
	password   string
	kms        string
	tinkKEKURI string
}

type Option func(*signerVerifierConfig)

// WithFile configures a file-based signer-verifier with an optional password.
func WithFile(filePath, password string) Option {
	return func(sc *signerVerifierConfig) {
		sc.filePath = filePath
		sc.password = password
	}
}

// WithKMS configures an Azure Key Vault signer-verifier, with a key in the form
// azurekms://[VAULT_NAME].vault.azure.net/[KEY_NAME].
//
// Unlike the gcp and aws equivalents, this takes no hash algorithm. The Azure
// provider ignores the hash passed to kms.Get, and instead selects SHA-256,
// SHA-384, or SHA-512 based on the algorithm of the Key Vault key itself, so
// accepting a hash here would let callers configure a digest that is silently
// never used.
func WithKMS(kmsKey string) Option {
	return func(sc *signerVerifierConfig) {
		sc.kms = kmsKey
	}
}

// WithTink configures a Tink signer-verifier, which is not supported for Azure.
//
// This option is retained for parity with the gcp and aws signerverifier
// packages so that a caller gets an explicit error rather than falling through
// to a confusing "insufficient signing parameters" message. There is no
// tink-go-azurekms integration in any language; upstream Tink declined to build
// one (google/tink#158).
func WithTink(kekURI, _ string) Option {
	return func(sc *signerVerifierConfig) {
		sc.tinkKEKURI = kekURI
	}
}
