/Users/Dev/homebrew/Cellar/toml-test/2.2.0/bin/toml-test \
test \
-toml=1.1.0 \
-color=never \
--decoder="nvim -l run_decoder.lua" \
--encoder="nvim -l run_encoder.lua" \
--skip valid/integer/long --skip valid/integer/float64-max
