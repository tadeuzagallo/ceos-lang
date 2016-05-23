CC = clang++
CFLAGS = -g -O0 -Wall -Wextra -std=c++11 -I .
LIBS = 

define source_glob
$(shell find . -name $(1) -not -path './tests/*')
endef

HEADERS = $(call source_glob, '*.h')
SOURCES = $(call source_glob, '*.cc') $(call source_glob, '*.S')
OBJECTS = $(patsubst %,.build/%.o,$(SOURCES))
TARGET = ceos

default:
	@make -j $(shell sysctl -n hw.ncpu) $(TARGET)

.PRECIOUS: $(TARGET) $(OBJECTS)

$(TARGET): $(OBJECTS)
	$(CC) $(CFLAGS) $(OBJECTS) $(LIBS) -o $@

.build/%.cc.o: %.cc $(HEADERS)
	@mkdir -p $$(dirname $@)
	$(CC) $(CFLAGS) -c $< -o $@

.build/%.S.o: %.S $(HEADERS)
	@mkdir -p $$(dirname $@)
	$(CC) $(CFLAGS) -c $< -o $@

# ERROR TESTS

ERROR_TESTS = $(patsubst %.ceos,.build/%.test,$(wildcard tests/errors/*.ceos))

.PHONY: error_test .build/tests/errors/%.test

error_test: $(ERROR_TESTS)

.build/tests/errors/%.test: tests/errors/%.ceos tests/errors/%.err $(TARGET)
	@mkdir -p $$(dirname $@)
	@sh -c "trap '' 6; ./$(TARGET) $<" > /dev/null 2> $@; \
	if [[ $$? == 0 ]]; then \
		echo "$@: ERROR!"; \
	else \
		diff \
			-I "libc++abi.dylib: terminating" \
			-I "Abort trap: 6" \
			$@ $(word 2, $^) && echo "$@: OK!" || echo "$@: FAIL!"; \
	fi

CPP_TESTS = $(patsubst %.cc,.build/%.test,$(wildcard tests/cpp/*.cc))

.PHONY: cpp_test .build/tests/cpp/%.test
cpp_test: $(CPP_TESTS) $(OBJECTS) $(HEADERS)

.build/tests/cpp/%.test: tests/cpp/%.cc $(OBJECTS) $(HEADERS)
	@mkdir -p $$(dirname $@)
	@$(CC) $(CFLAGS) $< $(filter-out %ceos.cc.o,$(OBJECTS)) $(LIBS) -I ./ -o $@
	@$@; \
	if [[ $$? != 0 ]]; then echo "$@: FAIL!"; else echo "$@: OK!"; fi

# TESTS

TESTS = $(patsubst %.ceos,.build/%.test,$(wildcard tests/*.ceos))

.PHONY: test .build/tests/%.test

test: $(TESTS) error_test cpp_test

.build/tests/%.test: tests/%.ceos tests/%.out $(TARGET)
	@mkdir -p $$(dirname $@)
	-@./$(TARGET) $< > $@; \
	if [[ $$? != 0 ]]; then echo "$@: ERROR!"; else diff $@ $(word 2, $^) && echo "$@: OK!" || echo "$@: FAIL!"; fi

.PHONY: tests/%.test

tests/%.test: .build/tests/%.test
	@#

# CLEAN

clean:
	-rm -rf $(OBJECTS) $(TARGET) $(TARGET).dSYM $(wildcard tests/*.test_)

.PHONY: clean
