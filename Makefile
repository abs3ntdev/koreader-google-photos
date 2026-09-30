SHELL := /bin/sh
LUA ?= luajit

.PHONY: check service-check plugin-check smoke package

check: service-check plugin-check smoke

service-check:
	npm --prefix service run check

plugin-check:
	$(LUA) plugin/spec/run.lua

smoke:
	node scripts/smoke-service.mjs

package: check
	sh scripts/package-plugin.sh
