.PHONY: test test-file stress-test syntax-gallery lint

test:
	nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua', sequential = true}"

# Run a single test file
test-file:
	nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile $(FILE)"

stress-test:
	nvim --headless -u tests/minimal_init.lua -c "lua require('tests.stress').run()" -c "qa!"

syntax-gallery:
	nvim -u tests/minimal_init.lua -c "lua require('tests.syntax_gallery').open()"

# Lint with luacheck (if installed)
lint:
	luacheck lua/ --no-unused-args --no-max-line-length
