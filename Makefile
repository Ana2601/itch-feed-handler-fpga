RTL   := rtl/itch_parser.sv rtl/order_book.sv rtl/itch_feed_handler.sv
BUILD := build
N     ?= 40000

.PHONY: test lint synth clean

test:
	@mkdir -p $(BUILD)
	python3 scripts/gen_feed.py $(BUILD) $(N)
	iverilog -g2012 -o $(BUILD)/tb.vvp $(RTL) tb/tb_feed.sv
	vvp -n $(BUILD)/tb.vvp +dir=$(BUILD) +gap=0
	vvp -n $(BUILD)/tb.vvp +dir=$(BUILD) +gap=30

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --top-module itch_feed_handler $(RTL)

synth:
	@mkdir -p $(BUILD)
	yosys -q -p "read_verilog -sv $(RTL); synth -top itch_parser; tee -o $(BUILD)/synth_parser.txt stat"

clean:
	rm -rf $(BUILD)
