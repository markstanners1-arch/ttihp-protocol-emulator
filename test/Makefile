# Makefile
# See https://docs.cocotb.org/en/stable/quickstart.html for more info

# defaults
SIM ?= icarus
FST ?= -fst # Use more efficient FST format
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../src
PROJECT_SOURCES = project.v chip.v cluster.v serialiser.v receiver.v crc32.v host_spi.v engine.v prog_mem.v fifo_mem.v glitch_filter.v sram_64x16.v sram_1024x16.v

ifneq ($(GATES),yes)

# RTL simulation:
SIM_BUILD				= sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
# the one IHP cell the wrapper names (the receive pin's latch), as a behavioural model
VERILOG_SOURCES += $(PWD)/rtl_cells.v

else

# Gate level simulation:
SIM_BUILD				= sim_build/gl
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DSIM
# Cell models for the PDK in $(PDK) (ihp-sg13cmos5l or ihp-sg13g2), e.g. sg13cmos5l_stdcell.v
PDK ?= ihp-sg13cmos5l
PDK_CELL_PREFIX = $(patsubst ihp-%,%,$(PDK))
PDK_LIBS_REF = $(PDK_ROOT)/$(PDK)/libs.ref
VERILOG_SOURCES += $(PDK_LIBS_REF)/$(PDK_CELL_PREFIX)_io/verilog/$(PDK_CELL_PREFIX)_io.v
# Newer PDK versions ship the UDP (user-defined primitive) models in a separate file
VERILOG_SOURCES += $(wildcard $(PDK_LIBS_REF)/$(PDK_CELL_PREFIX)_stdcell/verilog/$(PDK_CELL_PREFIX)_udp.v)
VERILOG_SOURCES += $(PDK_LIBS_REF)/$(PDK_CELL_PREFIX)_stdcell/verilog/$(PDK_CELL_PREFIX)_stdcell.v

# this gets copied in by the GDS action workflow
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v
# the netlist keeps the SRAM macro as a black box: its behavioural model comes from here
VERILOG_SOURCES += $(SRC_DIR)/sram_64x16.v $(SRC_DIR)/sram_1024x16.v

endif

# Allow sharing configuration between design and testbench via `include`:
COMPILE_ARGS 		+= -I$(SRC_DIR)
# the IHP SRAM macro as program store (prog_mem.v), and its behavioural model (sram_64x16.v)
COMPILE_ARGS 		+= -DUSE_SRAM -DCOCOTB_SIM

# Include the testbench sources:
VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb

# List test modules to run, separated by commas and without the .py suffix:
COCOTB_TEST_MODULES = test

# include cocotb's make rules to take care of the simulator setup
include $(shell cocotb-config --makefiles)/Makefile.sim
