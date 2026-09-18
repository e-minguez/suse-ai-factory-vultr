# Fixture for TestRedaction: every value below is FABRICATED for this test.
# None of it is a real credential, but each is shaped like the real thing --
# a $6$ shadow hash, an "nvapi-" NGC token, an ed25519 public key, a long
# base64 blob -- so the test proves the pipeline never echoes a secret-shaped
# value, not merely that it never echoes THE real ones. This file is
# deliberately parseable: TestRedactionMalformed covers the syntax-error path.
region = "ams"

vultr_api_key = "F3C9A18B2D6E4F0A9B7C5D3E1F0A2B4C6D8E1F3A5B7C9D0E2F4A6B8C0D2E4F6A"

admin_cidrs = ["203.0.113.5/32"]

root_password_hash      = "$6$rounds=656000$aVeryFakeSaltStr$q1w2e3r4t5y6u7i8o9p0AsDfGhJkLzXcVbNmQwErTyUiOpAsDfGhJkLzXcVbNmQwErTyUiOpAsDfGhJkLz"
node_user_password_hash = "$6$rounds=656000$anotherFakeSalt$z9x8c7v6b5n4m3l2k1j0HgFdSaPoIuYtReWqZxCvBnMlKjHgFdSaPoIuYtReWqZxCvBnMlKjHgFdSa"

ssh_authorized_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderFakeKeyMaterialDoesNotDecodeToAnythingReal fake@example"]

appco_username = "fake-appco-user"
appco_password = "fake-appco-token-Zm9vYmFyYmF6cXV1eA=="

suse_registration_code = "FAKE-1234-5678-9ABC-DEF0"
suse_registry_password = "fake-suse-registry-password-9f8e7d6c5b4a"

nvidia_api_key = "nvapi-FAKEkQ1w2E3r4T5y6U7i8O9p0AsDfGhJkLzXcVbNmQwErTyUiOpAsDfGhJk"

# Pricing-relevant fields, so the pipeline actually runs end to end.
control_plane_plan = "vx1-g-4c-16g-240s"
jumphost_plan       = "vc2-6c-16gb"
