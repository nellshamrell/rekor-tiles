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
		return kms.Get(ctx, sc.kms, crypto.Hash(0))
	case sc.tinkKEKURI != "":
		return nil, fmt.Errorf("tink is not supported for Azure Key Vault; use a KMS or file signer-verifier instead")
	case sc.filePath != "":
		return sv.NewFileSignerVerifier(sc.filePath, sc.password)
	default:
		return nil, fmt.Errorf("insufficient signing parameters provided, must configure one of file or KMS signer-verifiers")
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
