# Makefile for yaml
#
# Supports cross-compilation via TARGET parameter:
#   TARGET=x86_64-linux-musl make static   # Linux x64
#   TARGET=x86_64-windows-gnu make static  # Windows x64
#   make static                             # native (default)

PROJECT=yaml

CROSS_PREFIX :=
PP=$(CROSS_PREFIX)cpp

# Use zig cc for cross-compilation when TARGET is set
ifeq ($(TARGET),)
    CC=$(CROSS_PREFIX)gcc
    AR=$(CROSS_PREFIX)ar
    LD=$(CROSS_PREFIX)ld
else
    CC=zig cc -target $(TARGET)
    LD=zig cc -target $(TARGET)
    AR=zig ar -target $(TARGET)
endif

CCFLAGS=-O3 -pipe $(CFLAGS)
LDFLAGS=$(LFLAGS)

SRCDIR=src
BINDIR=bin
BUILDDIR=build

STATIC_TARGET=$(BINDIR)/lib$(PROJECT).a
SHARED_TARGET=$(BINDIR)/lib$(PROJECT).so

$(SHARED_TARGET) : CCFLAGS+=-fPIC
$(SHARED_TARGET) : LDFLAGS+=-shared

-include build.mk
-include configs.mk
CCFLAGS+=-I$(SRCDIR) $(CONFIG_CFLAGS)

CCSRCS=$(filter %.c,$(SRCFILES))
ASSRCS=$(filter %.S,$(SRCFILES))
LDOBJS=$(patsubst $(SRCDIR)/%.c,$(BUILDDIR)/%.o,$(CCSRCS)) \
       $(patsubst $(SRCDIR)/%.S,$(BUILDDIR)/%.o,$(ASSRCS))
DEPEND=$(LDOBJS:.o=.dep)

BUILDMSG="\e[1;31mBUILD\e[0m %s\n"
LINKMSG="\e[1;34mLINK\e[0m  \e[1;32m%s\e[0m\n"
CLEANMSG="\e[1;34mCLEAN\e[0m %s\n"
TESTMSG="\e[1;34mTEST\e[0m  \e[1;32m%s\e[0m\n"

V:=
ECHO_PREFIX:=@
ifeq ($(V),1)
    undefine ECHO_PREFIX
endif

.PHONY: static shared clean

static : $(STATIC_TARGET)

shared : $(SHARED_TARGET)

clean :
	$(ECHO_PREFIX) $(RM) -rf $(BINDIR) $(BUILDDIR)
	@printf $(CLEANMSG) $(PROJECT)

$(STATIC_TARGET) : $(LDOBJS)
	$(ECHO_PREFIX) mkdir -p $(dir $@)
	$(ECHO_PREFIX) if echo "$(AR)" | grep -q "zig ar"; then \
		$(AR) rcs $@ $^; \
	else \
		$(AR) csq $@ $^; \
	fi
	@printf $(LINKMSG) $@

$(SHARED_TARGET) : $(LDOBJS)
	$(ECHO_PREFIX) mkdir -p $(dir $@)
	$(ECHO_PREFIX) $(CC) -o $@ $^ $(LDFLAGS)
	@printf $(LINKMSG) $@

$(BUILDDIR)/%.dep : $(SRCDIR)/%.c
	$(ECHO_PREFIX) mkdir -p $(dir $@)
	$(ECHO_PREFIX) $(PP) $(CCFLAGS) -MM -MT$(@:.dep=.o) -MF$@ $< 2>/dev/null

$(BUILDDIR)/%.dep : $(SRCDIR)/%.S
	$(ECHO_PREFIX) mkdir -p $(dir $@)
	$(ECHO_PREFIX) $(PP) $(CCFLAGS) -MM -MT$(@:.dep=.o) -MF$@ $< 2>/dev/null

$(BUILDDIR)/%.o : $(SRCDIR)/%.c
	$(ECHO_PREFIX) mkdir -p $(dir $@)
	$(ECHO_PREFIX) $(CC) $(CCFLAGS) -c -o $@ $<
	@printf $(BUILDMSG) $<

$(BUILDDIR)/%.o : $(SRCDIR)/%.S
	$(ECHO_PREFIX) mkdir -p $(dir $@)
	$(ECHO_PREFIX) $(CC) $(CCFLAGS) -c -o $@ $<
	@printf $(BUILDMSG) $<

ifneq ($(MAKECMDGOALS),clean)
-include $(DEPEND)
endif
