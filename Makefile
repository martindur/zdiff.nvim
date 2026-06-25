.PHONY: test test-file stress-test syntax-gallery syntax-gallery-clean format lint

test:
	nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua', sequential = true}"

# Run a single test file
test-file:
	nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile $(FILE)"

stress-test:
	nvim --headless -u tests/minimal_init.lua -c "lua require('tests.stress').run()" -c "qa!"

syntax-gallery:
	nvim --cmd "set runtimepath^=$(CURDIR)" -c "lua require('tests.syntax_gallery').open()"

syntax-gallery-clean:
	nvim -u tests/minimal_init.lua -c "lua require('tests.syntax_gallery').open()"

format:
	stylua lua/ plugin/ tests/

lint:
	luacheck lua/ --globals vim --no-unused-args --no-max-line-length
