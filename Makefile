.PHONY: check
check:   ## everything a PR must pass
	dart pub get
	dart format --output=none --set-exit-if-changed .
	dart analyze --fatal-infos
	dart run rynsy_rules check
	dart test
