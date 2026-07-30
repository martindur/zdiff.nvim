.PHONY: test test-file format lint

test:
	nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua', sequential = true}"

# Run a single test file
test-file:
	nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile $(FILE)"

format:
	stylua lua/ plugin/ tests/

lint:
	luacheck lua/ --globals vim --no-unused-args --no-max-line-length
