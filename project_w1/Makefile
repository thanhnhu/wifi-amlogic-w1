TARGET=vlsicomm.ko

#PROJECT=PROJECT_W1
#export PROJECT
export PROJ_NAME

# -----------------------------------------------------------------------
# Debian / mainline kernel build
# To build the driver against the running Debian kernel:
#   make driver
# To cross-compile (e.g. from x86 host for arm64 target):
#   make driver ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
#               KERNELDIR=/path/to/kernel/build
# -----------------------------------------------------------------------

all: driver

driver:
	$(MAKE) -C vmac

clean:
	$(MAKE) clean -C vmac
	rm -f $(TARGET)

.PHONY: driver clean
