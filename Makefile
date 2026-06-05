TESTS_INIT=tests/init.lua
TESTS_DIR=tests/

.PHONY: all
all:test

.PHONY: unit_test
unit_test:
	@nvim \
		--headless \
		--noplugin \
		-u ${TESTS_INIT} \
		-c "lua require('plenary.test_harness').test_directory('${TESTS_DIR}', { init = '${TESTS_INIT}' })"


.PHONY: toml_test
toml_test:
	@cd tests && /Users/Dev/homebrew/Cellar/toml-test/2.2.0/bin/toml-test \
		test \
		--toml=1.1.0 \
		--color=never \
		--timeout=3s \
		--decoder="nvim -l run_decoder.lua" \
		--encoder="nvim -l run_encoder.lua" \
		--skip valid/integer/long \
		--skip valid/integer/float64-max \
		--skip encoder/integer/long

.PHONY: test
test: unit_test toml_test


