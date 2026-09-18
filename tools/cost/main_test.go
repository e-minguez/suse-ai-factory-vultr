package main

import (
	"bytes"
	"os"
	"strings"
	"testing"
)

// fakeSecrets lists every fabricated-but-real-shaped secret substring the
// testdata/redact_*.tfvars fixtures carry. None of these are real
// credentials -- see the fixtures' own header comments -- but each is
// SHAPED like one, which is the point: this proves the pipeline never
// echoes a secret-shaped value, not merely that it never echoes one
// specific real secret.
var fakeSecrets = []string{
	"F3C9A18B2D6E4F0A9B7C5D3E1F0A2B4C6D8E1F3A5B7C9D0E2F4A6B8C0D2E4F6A",
	"rounds=656000$aVeryFakeSaltStr",
	"rounds=656000$anotherFakeSalt",
	"AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderFakeKeyMaterial",
	"nvapi-FAKEkQ1w2E3r4T5y6U7i8O9p0AsDfGhJkLzXcVbNmQwErTyUiOpAsDfGhJk",
	"fake-appco-token-Zm9vYmFyYmF6cXV1eA==",
	"FAKE-1234-5678-9ABC-DEF0",
	"fake-suse-registry-password-9f8e7d6c5b4a",
}

const testPlansFile = "internal/vultr/testdata/plans.json"

func assertNoSecrets(t *testing.T, label string, output []byte) {
	t.Helper()
	s := string(output)
	for _, secret := range fakeSecrets {
		if strings.Contains(s, secret) {
			t.Errorf("%s leaked a secret-shaped substring %q:\n%s", label, secret, s)
		}
	}
}

// TestRedactionValidTFVars runs the full pipeline -- parse, resolve, price,
// render -- over a tfvars carrying every sensitive variable the real module
// declares, filled with structurally-real fake secrets, in both text and
// JSON, and checks both stdout and stderr.
func TestRedactionValidTFVars(t *testing.T) {
	for _, jsonMode := range []bool{false, true} {
		args := []string{"--no-network", "--plans", testPlansFile, "testdata/redact_valid.tfvars"}
		if jsonMode {
			args = append([]string{"--json"}, args...)
		}
		var stdout, stderr bytes.Buffer
		code := run(args, &stdout, &stderr)
		if code != exitOK {
			t.Fatalf("json=%v: exit code = %d, want 0. stderr: %s", jsonMode, code, stderr.String())
		}
		assertNoSecrets(t, "stdout", stdout.Bytes())
		assertNoSecrets(t, "stderr", stderr.Bytes())
	}
}

// TestRedactionMalformedTFVars covers the diagnostic path specifically: a
// deliberately unterminated string literal sitting on a secret value
// produces an HCL parse diagnostic, and Diagnostic.Format/FromHCLDiagnostics
// must not let that diagnostic's Detail (which can include the
// partially-scanned token) reach stdout or stderr.
func TestRedactionMalformedTFVars(t *testing.T) {
	for _, jsonMode := range []bool{false, true} {
		args := []string{"--no-network", "--plans", testPlansFile, "testdata/redact_malformed.tfvars"}
		if jsonMode {
			args = append([]string{"--json"}, args...)
		}
		var stdout, stderr bytes.Buffer
		code := run(args, &stdout, &stderr)
		if code != exitConfig {
			t.Fatalf("json=%v: exit code = %d, want %d (config error). stdout: %s stderr: %s", jsonMode, code, exitConfig, stdout.String(), stderr.String())
		}
		assertNoSecrets(t, "stdout", stdout.Bytes())
		assertNoSecrets(t, "stderr", stderr.Bytes())
	}
}

// TestRunAgainstExampleTFVars exercises the real end-to-end path used by the
// plan's own Verification section, minus network access.
func TestRunAgainstExampleTFVars(t *testing.T) {
	var stdout, stderr bytes.Buffer
	args := []string{"--no-network", "--plans", testPlansFile, "../../examples/ha-cluster/terraform.tfvars.example"}
	code := run(args, &stdout, &stderr)
	if code != exitOK {
		t.Fatalf("exit code = %d, want 0. stderr: %s", code, stderr.String())
	}
	out := stdout.String()
	for _, want := range []string{"jumphost", "control plane", "load balancer (api)", "nat gateway", "snapshot storage", "TOTAL"} {
		if !strings.Contains(out, want) {
			t.Errorf("expected output to contain %q:\n%s", want, out)
		}
	}
}

// TestRunMissingRegionExitsConfig asserts the "region absent" row of the
// plan's error-handling table: exit 2, and the message mentions --region.
func TestRunMissingRegionExitsConfig(t *testing.T) {
	tfvars := t.TempDir() + "/no-region.tfvars"
	if err := writeFile(tfvars, "control_plane_plan = \"vx1-g-4c-16g-240s\"\n"); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	code := run([]string{"--no-network", "--plans", testPlansFile, tfvars}, &stdout, &stderr)
	if code != exitConfig {
		t.Fatalf("exit code = %d, want %d. stderr: %s", code, exitConfig, stderr.String())
	}
	if !strings.Contains(stderr.String(), "--region") {
		t.Errorf("expected stderr to mention --region, got: %s", stderr.String())
	}
}

// TestRunRegionFlagOverridesMissingTFVars proves --region alone is enough
// even when the tfvars sets none.
func TestRunRegionFlagOverridesMissingTFVars(t *testing.T) {
	tfvars := t.TempDir() + "/no-region.tfvars"
	if err := writeFile(tfvars, "control_plane_plan = \"vx1-g-4c-16g-240s\"\n"); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	code := run([]string{"--region", "ams", "--no-network", "--plans", testPlansFile, tfvars}, &stdout, &stderr)
	if code != exitOK {
		t.Fatalf("exit code = %d, want 0. stderr: %s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "Region: ams") {
		t.Errorf("expected output to show the overridden region, got: %s", stdout.String())
	}
}

// TestRunUnknownPlanExitsPrice asserts exit 3 for an unrecognised plan ID at
// qty >= 1, and exit 0 with --allow-unknown-plans.
func TestRunUnknownPlanExitsPrice(t *testing.T) {
	tfvars := t.TempDir() + "/unknown-plan.tfvars"
	if err := writeFile(tfvars, "region = \"ams\"\ncontrol_plane_plan = \"vx1-does-not-exist\"\n"); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	code := run([]string{"--no-network", "--plans", testPlansFile, tfvars}, &stdout, &stderr)
	if code != exitPrice {
		t.Fatalf("exit code = %d, want %d (pricing data). stderr: %s", code, exitPrice, stderr.String())
	}

	stdout.Reset()
	stderr.Reset()
	code = run([]string{"--no-network", "--plans", testPlansFile, "--allow-unknown-plans", tfvars}, &stdout, &stderr)
	if code != exitOK {
		t.Fatalf("with --allow-unknown-plans: exit code = %d, want 0. stderr: %s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "floor") {
		t.Errorf("expected the incomplete-total note, got: %s", stdout.String())
	}
}

// TestRunNoNetworkNoPlansNoCacheExitsPrice: with no --plans, no network, and
// (almost certainly, in a test environment) no warm cache, pricing has
// nothing to work from at all.
func TestRunNoNetworkNoPlansNoCacheExitsPrice(t *testing.T) {
	tfvars := t.TempDir() + "/minimal.tfvars"
	if err := writeFile(tfvars, "region = \"ams\"\n"); err != nil {
		t.Fatal(err)
	}
	// os.UserCacheDir() reads $HOME on darwin and $XDG_CACHE_HOME/$HOME on
	// linux; overriding both guarantees no warm cache is found regardless of
	// the OS this test runs on.
	empty := t.TempDir()
	t.Setenv("HOME", empty)
	t.Setenv("XDG_CACHE_HOME", empty)
	var stdout, stderr bytes.Buffer
	code := run([]string{"--no-network", tfvars}, &stdout, &stderr)
	if code != exitPrice {
		t.Fatalf("exit code = %d, want %d. stdout: %s stderr: %s", code, exitPrice, stdout.String(), stderr.String())
	}
}

func writeFile(path, content string) error {
	return os.WriteFile(path, []byte(content), 0o644)
}
