# Makefile for Ọ̀ṢỌ́VM
# Àṣẹ! Build the sacred compiler

.PHONY: test run-example clean help

# Run full test suite via runtests.jl (spawns each file as its own subprocess)
# Pass 'fast' to skip benchmarks: make test ARGS=fast
test:
	@echo "Running Ọ̀ṢỌ́VM test suite..."
	julia --project=. test/runtests.jl $(ARGS)

# Run hello world example
run-example:
	@echo "🌄 Running hello_oso.oso..."
	julia -e 'push!(LOAD_PATH, "src"); \
		include("src/oso_compiler.jl"); \
		include("src/oso_vm.jl"); \
		using .OsoCompiler, .OsoVM; \
		source = read("examples/hello_oso.oso", String); \
		ir = OsoCompiler.compile_oso(source); \
		vm = OsoVM.create_vm(); \
		results = OsoVM.execute_ir(vm, ir); \
		OsoVM.print_state(vm); \
		println("Results: ", results)'

# Run work cycle example
run-work:
	@echo "⚡ Running work_cycle.oso..."
	julia -e 'push!(LOAD_PATH, "src"); \
		include("src/oso_compiler.jl"); \
		include("src/oso_vm.jl"); \
		using .OsoCompiler, .OsoVM; \
		source = read("examples/work_cycle.oso", String); \
		ir = OsoCompiler.compile_oso(source); \
		vm = OsoVM.create_vm(); \
		results = OsoVM.execute_ir(vm, ir, sender="worker"); \
		OsoVM.print_state(vm)'

# Run 1440 inheritance example
run-1440:
	@echo "🤍 Running inheritance_1440.oso..."
	julia -e 'push!(LOAD_PATH, "src"); \
		include("src/oso_compiler.jl"); \
		include("src/oso_vm.jl"); \
		using .OsoCompiler, .OsoVM; \
		source = read("examples/inheritance_1440.oso", String); \
		ir = OsoCompiler.compile_oso(source); \
		vm = OsoVM.create_vm(); \
		results = OsoVM.execute_ir(vm, ir); \
		println("1440 Wallet Results: ", results)'

# Clean build artifacts
clean:
	@echo "🧹 Cleaning build artifacts..."
	find . -name "*.ji" -delete
	find . -name "*.o" -delete
	@echo "✅ Clean complete"

# Show help
help:
	@echo "Ọ̀ṢỌ́VM Makefile"
	@echo "==============="
	@echo ""
	@echo "Available targets:"
	@echo "  make test       - Run test suite"
	@echo "  make run-example - Run hello_oso.oso"
	@echo "  make run-work   - Run work_cycle.oso"
	@echo "  make run-1440   - Run inheritance_1440.oso"
	@echo "  make clean      - Clean build artifacts"
	@echo "  make help       - Show this help"
	@echo ""
	@echo "Àṣẹ! 🔥"

# Default target
all: test
