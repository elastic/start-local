#!/bin/bash
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. See the NOTICE file distributed with
# this work for additional information regarding copyright
# ownership. Elasticsearch B.V. licenses this file to you under
# the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#	http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
# Regression test for https://github.com/elastic/start-local/issues/79 (Bug 2):
# On rolling-release distros like Arch Linux, /etc/os-release does not define VERSION.
# With `set -eu`, bare $VERSION causes an "unbound variable" crash.
# The fix uses ${VERSION:-} to default to an empty string.

# Test that the fixed code pattern does not crash when VERSION is absent from os-release
function test_get_os_info_succeeds_when_VERSION_is_not_defined() {
    tmpdir=$(mktemp -d)
    cat > "${tmpdir}/os-release" << 'EOF'
NAME="Arch Linux"
ID=arch
PRETTY_NAME="Arch Linux"
HOME_URL="https://archlinux.org/"
EOF

    # Run the exact code path from get_os_info() under set -eu.
    # ${VERSION:-} should safely default to "" when VERSION is not exported.
    output=$(bash -euc "
        . '${tmpdir}/os-release'
        echo \"Distribution: \$NAME\"
        echo \"Version: \${VERSION:-}\"
    " 2>&1)
    exit_code=$?
    rm -rf "${tmpdir}"

    assert_equals "0" "${exit_code}"
    assert_contains "Arch Linux" "${output}"
}

# Confirm that the unfixed pattern ($VERSION without :-) would have crashed,
# making the above test meaningful.
function test_bare_VERSION_crashes_under_set_eu_when_not_defined() {
    tmpdir=$(mktemp -d)
    cat > "${tmpdir}/os-release" << 'EOF'
NAME="Arch Linux"
ID=arch
EOF

    bash -euc "
        . '${tmpdir}/os-release'
        echo \"\$VERSION\"
    " > /dev/null 2>&1
    exit_code=$?
    rm -rf "${tmpdir}"

    assert_not_equals "0" "${exit_code}"
}
