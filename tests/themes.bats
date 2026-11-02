#!/usr/bin/env bats
# CLI тем запускается с изолированным XDG_CONFIG_HOME, настоящий agterm не нужен.
@test "Rex import apply reset and invalid inputs" {
    run python3 -m unittest discover -s "$BATS_TEST_DIRNAME/../themes/tests" -v
    [ "$status" -eq 0 ]
}
