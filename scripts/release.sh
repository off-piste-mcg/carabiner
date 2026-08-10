#!/usr/bin/env bash
# Build, notarize and staple a distributable Carabiner.dmg.
#
# Usage: ./scripts/release.sh [version]
#
# Everything here needs a Developer ID Application certificate and a stored notarytool
# credential profile — see docs/superpowers/specs/2026-08-10-developer-id-distribution-design.md.
# The script refuses to start without them rather than failing halfway through a build.
#
# Sourceable: `source scripts/release.sh` defines the functions and runs nothing, which
# is how test/test-release.sh exercises the preflight gate without doing a build.
set -uo pipefail

IDENTITY="Developer ID Application"
NOTARY_PROFILE="carabiner"

die()  { printf 'release: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }

# The team ID lives in the certificate's OU field. NOT the parenthetical in the identity
# name — that is the agent ID, and signing with it fails with "No signing certificate
# matching team ID". Same trap as gotcha #12, different certificate.
developer_id_team() {
  security find-certificate -a -c "$IDENTITY" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | tr ',/' '\n\n' \
    | sed -nE 's/.*OU=([A-Z0-9]{10}).*/\1/p' \
    | head -1
}

require_developer_id_cert() {
  [ -n "$(developer_id_team)" ] || die "no \"$IDENTITY\" certificate in the keychain.
  Create one: Xcode > Settings > Accounts > the OFF-PISTE team > Manage Certificates
  > + > Developer ID Application. Needs the Account Holder role."
}

require_notary_profile() {
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "no stored notarytool profile named \"$NOTARY_PROFILE\".
  Create one: xcrun notarytool store-credentials $NOTARY_PROFILE
  It asks for your Apple ID, the team ID, and an app-specific password
  from appleid.apple.com (not your account password)."
}

main() {
  require_developer_id_cert
  require_notary_profile
  note "preconditions ok — team $(developer_id_team)"
}

# Run only when executed, never when sourced.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
