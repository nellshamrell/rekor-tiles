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

package app

import (
	"strings"
	"testing"

	"github.com/spf13/viper"
)

func TestSignerOptions(t *testing.T) {
	tests := []struct {
		name     string
		filepath string
		password string
		kmsKey   string
		wantOpts int
		wantErr  string
	}{
		{
			name:     "file only",
			filepath: "/pki/key.pem",
			wantOpts: 1,
		},
		{
			name:     "file with password",
			filepath: "/pki/key.pem",
			password: "hunter2",
			wantOpts: 1,
		},
		{
			name:     "kms only",
			kmsKey:   "azurekms://vault.vault.azure.net/key",
			wantOpts: 1,
		},
		{
			name:     "both set is ambiguous",
			filepath: "/pki/key.pem",
			kmsKey:   "azurekms://vault.vault.azure.net/key",
			wantErr:  "only one of --signer-filepath and --signer-kmskey may be set",
		},
		{
			name:    "neither set",
			wantErr: "no signer configured",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			opts, err := signerOptions(tt.filepath, tt.password, tt.kmsKey)
			if tt.wantErr != "" {
				if err == nil {
					t.Fatalf("expected error containing %q, got nil", tt.wantErr)
				}
				if !strings.Contains(err.Error(), tt.wantErr) {
					t.Errorf("expected error containing %q, got %q", tt.wantErr, err.Error())
				}
				if opts != nil {
					t.Errorf("expected no options alongside an error, got %d", len(opts))
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(opts) != tt.wantOpts {
				t.Errorf("expected %d options, got %d", tt.wantOpts, len(opts))
			}
		})
	}
}

// TestSignerFlagsRegistered guards the flags the serve command relies on, and
// asserts that the flags which don't apply to Azure Key Vault are absent.
// --signer-kmshash in particular must not exist: the Azure provider ignores the
// hash passed to kms.Get and derives it from the key, so offering the flag would
// silently mislead.
func TestSignerFlagsRegistered(t *testing.T) {
	for _, name := range []string{"signer-filepath", "signer-password", "signer-kmskey"} {
		if serveCmd.Flags().Lookup(name) == nil {
			t.Errorf("expected flag --%s to be registered", name)
		}
	}
	for _, name := range []string{"signer-kmshash", "signer-tink-kek-uri", "signer-tink-keyset-path"} {
		if serveCmd.Flags().Lookup(name) != nil {
			t.Errorf("flag --%s must not be registered; it does not apply to Azure Key Vault", name)
		}
	}
}

// TestStorageFlagsRegistered confirms the POSIX storage flags survived the fork
// from the posix command.
func TestStorageFlagsRegistered(t *testing.T) {
	for _, name := range []string{"storage-dir", "identity-mode"} {
		if serveCmd.Flags().Lookup(name) == nil {
			t.Errorf("expected flag --%s to be registered", name)
		}
	}
}

// TestFlagsBoundToViper confirms init() bound the signer flags, since the serve
// command reads them through viper rather than from the flag set.
func TestFlagsBoundToViper(t *testing.T) {
	for _, name := range []string{"signer-filepath", "signer-kmskey", "storage-dir"} {
		if !viper.IsSet(name) && viper.Get(name) == nil {
			t.Errorf("expected flag --%s to be bound to viper", name)
		}
	}
}
