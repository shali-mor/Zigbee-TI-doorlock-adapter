INSTALL_DIR= /opt/rainbow/bundles
BUILD_DIR= .build

LUAC= luac

ifeq ($(COMPILE_STRIP), y)
define STRIP_CMDS
	find $(BUILD_DIR) -type f -name "*.lua" -print | \
	  xargs -I % $(LUAC) -s -o % %
endef
endif

TI_ZB_DOORLOCK_ADAPTER_TAR= ti_zb_doorlock_adapter.tar.gz
TI_ZB_DOORLOCK_ADAPTER_FILES= RainbowManifest.json ti_zigb_dl_ctrl_adapter.lua CC2531Ctr.lua

$(BUILD_DIR): $(TI_ZB_DOORLOCK_ADAPTER_FILES)
	mkdir -p $(BUILD_DIR)
	touch $(BUILD_DIR)
	cp $^ $(BUILD_DIR)

$(TI_ZB_DOORLOCK_ADAPTER_TAR): $(BUILD_DIR)
	$(STRIP_CMDS)
	tar -czf $@ -C $< $(notdir $(wildcard $</*))

all: $(TI_ZB_DOORLOCK_ADAPTER_TAR)

install: all
	mkdir -p $(INSTALL_DIR)
	install -m 400 $(TI_ZB_DOORLOCK_ADAPTER_TAR) $(INSTALL_DIR)

clean:
	rm -rf $(TI_ZB_DOORLOCK_ADAPTER_TAR) $(BUILD_DIR)

uninstall:
	rm -f $(addprefix $(INSTALL_DIR)/,$(TI_ZB_DOORLOCK_ADAPTER_TAR))
	rmdir $(INSTALL_DIR)

.PHONY: all clean test
.DEFAULT_GOAL:= all