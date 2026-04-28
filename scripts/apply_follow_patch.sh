#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSET_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HEADER_ROOT="$ASSET_ROOT/include"
SOURCE_ROOT="$ASSET_ROOT/src/main/follow"
TARGET_ARCHIVE_ROOT="$ASSET_ROOT/target"

install_if_needed() {
  local mode="$1"
  local src="$2"
  local dst="$3"

  if [ ! -e "$src" ]; then
    echo "Missing required file: $src" >&2
    exit 1
  fi

  if [ -e "$dst" ] && [ "$(realpath "$src")" = "$(realpath "$dst")" ]; then
    return
  fi

  install -m "$mode" "$src" "$dst"
}

if [ ! -f "$ROOT_DIR/src/main/fc/init.c" ] || [ ! -f "$ROOT_DIR/src/main/rx/crsf.c" ]; then
  echo "Please run this script from the pristine betaflight-4.5.2 source root." >&2
  exit 1
fi

mkdir -p "$ROOT_DIR/src/main/follow"
mkdir -p "$ROOT_DIR/src/main/follow/target"
mkdir -p "$ROOT_DIR/src/config/configs"
find "$HEADER_ROOT/follow" -type f -name '*.h' | while read -r src; do
  rel="${src#$HEADER_ROOT/}"
  dst="$ROOT_DIR/src/main/$rel"
  mkdir -p "$(dirname "$dst")"
  install_if_needed 0644 "$src" "$dst"
done

find "$SOURCE_ROOT" -type f -name '*.c' ! -name 'follow_override_impl_template.c' | while read -r src; do
  rel="${src#$SOURCE_ROOT/}"
  dst="$ROOT_DIR/src/main/follow/$rel"
  mkdir -p "$(dirname "$dst")"
  install_if_needed 0644 "$src" "$dst"
done

if [ -d "$TARGET_ARCHIVE_ROOT" ]; then
  find "$TARGET_ARCHIVE_ROOT" -type f -name '*.a' | while read -r src; do
    rel="${src#$TARGET_ARCHIVE_ROOT/}"
    dst="$ROOT_DIR/src/main/follow/target/$rel"
    mkdir -p "$(dirname "$dst")"
    install_if_needed 0644 "$src" "$dst"
  done
fi

install_if_needed 0644 "$SOURCE_ROOT/follow_override_impl_template.c" "$ROOT_DIR/follow_override_impl_template.c"

python3 - <<'PY'
from pathlib import Path
import sys

root = Path(".")

def replace_once(rel_path: str, old: str, new: str) -> None:
    path = root / rel_path
    text = path.read_text()
    if new and new in text:
        return
    if old not in text:
        raise SystemExit(f"pattern not found in {rel_path}")
    path.write_text(text.replace(old, new, 1))

def remove_once(rel_path: str, old: str) -> None:
    path = root / rel_path
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"pattern not found in {rel_path}")
    path.write_text(text.replace(old, "", 1))

replace_once(
    "Makefile",
    """TARGET_OBJS     = $(addsuffix .o,$(addprefix $(TARGET_OBJ_DIR)/,$(basename $(SRC))))
TARGET_DEPS     = $(addsuffix .d,$(addprefix $(TARGET_OBJ_DIR)/,$(basename $(SRC))))
TARGET_MAP      = $(OBJECT_DIR)/$(FORKNAME)_$(TARGET_NAME).map

TARGET_EXST_HASH_SECTION_FILE = $(TARGET_OBJ_DIR)/exst_hash_section.bin
""",
    """TARGET_OBJS     = $(addsuffix .o,$(addprefix $(TARGET_OBJ_DIR)/,$(basename $(SRC))))
TARGET_DEPS     = $(addsuffix .d,$(addprefix $(TARGET_OBJ_DIR)/,$(basename $(SRC))))
TARGET_MAP      = $(OBJECT_DIR)/$(FORKNAME)_$(TARGET_NAME).map
TARGET_EXTRA_LINK_INPUTS ?=

TARGET_EXST_HASH_SECTION_FILE = $(TARGET_OBJ_DIR)/exst_hash_section.bin
""",
)

replace_once(
    "Makefile",
    """LD_FLAGS        :=
EXTRA_LD_FLAGS  :=

#
# Default Tool options - can be overridden in {mcu}.mk files.
#
""",
    """LD_FLAGS        :=
EXTRA_LD_FLAGS  :=

FOLLOW_VERSION ?= dev
FOLLOW_DESCRIPTION ?=
FOLLOW_WORK_SERIAL_PORT ?= SERIAL_PORT_UART4
FOLLOW_SIM_SERIAL_PORT ?= SERIAL_PORT_USART3

EXTRA_FLAGS += -D'FOLLOW_VERSION="$(FOLLOW_VERSION)"'
EXTRA_FLAGS += -D'FOLLOW_DESCRIPTION="$(FOLLOW_DESCRIPTION)"'
EXTRA_FLAGS += -D'FOLLOW_WORK_SERIAL_PORT=$(FOLLOW_WORK_SERIAL_PORT)'
EXTRA_FLAGS += -D'FOLLOW_SIM_SERIAL_PORT=$(FOLLOW_SIM_SERIAL_PORT)'

#
# Default Tool options - can be overridden in {mcu}.mk files.
#
""",
)

replace_once(
    "Makefile",
    """$(TARGET_ELF): $(TARGET_OBJS) $(LD_SCRIPT) $(LD_SCRIPTS)
\t@echo "Linking $(TARGET_NAME)" "$(STDOUT)"
\t$(V1) $(CROSS_CC) -o $@ $(filter-out %.ld,$^) $(LD_FLAGS)
\t$(V1) $(SIZE) $(TARGET_ELF)
""",
    """$(TARGET_ELF): $(TARGET_OBJS) $(TARGET_EXTRA_LINK_INPUTS) $(LD_SCRIPT) $(LD_SCRIPTS)
\t@echo "Linking $(TARGET_NAME)" "$(STDOUT)"
\t$(V1) $(CROSS_CC) -o $@ $(filter-out %.ld,$^) $(LD_FLAGS)
\t$(V1) $(SIZE) $(TARGET_ELF)
""",
)

replace_once(
    "src/main/fc/init.c",
    """#include "sensors/initialisation.h"

#include "telemetry/telemetry.h"
""",
    """#include "sensors/initialisation.h"

#include "telemetry/telemetry.h"
#include "follow/follow_bundle.h"
""",
)

remove_once(
    "src/main/fc/init.c",
    "    gyroStartCalibration(false);\n",
)

replace_once(
    "src/main/fc/init.c",
    """    unusedPinsInit();

    tasksInit();
""",
    """    unusedPinsInit();

    followTrackerInit();

    tasksInit();
""",
)

replace_once(
    "src/main/fc/tasks.c",
    """#include "tasks.h"

// taskUpdateRxMain() has occasional peaks in execution time so normal moving average duration estimation doesn't work
""",
    """#include "tasks.h"
#include "follow/follow_bundle.h"

// taskUpdateRxMain() has occasional peaks in execution time so normal moving average duration estimation doesn't work
""",
)

replace_once(
    "src/main/fc/tasks.c",
    """#ifdef USE_RC_STATS
    [TASK_RC_STATS] = DEFINE_TASK("RC_STATS", NULL, NULL, rcStatsUpdate, TASK_PERIOD_HZ(100), TASK_PRIORITY_LOW),
#endif

};
""",
    """#ifdef USE_RC_STATS
    [TASK_RC_STATS] = DEFINE_TASK("RC_STATS", NULL, NULL, rcStatsUpdate, TASK_PERIOD_HZ(100), TASK_PRIORITY_LOW),
#endif
    [TASK_FOLLOW_TRACKER] = DEFINE_TASK("FOLLOW_TRACKER", NULL, NULL, followTrackerTask, TASK_PERIOD_HZ(100), TASK_PRIORITY_MEDIUM),
    [TASK_FOLLOW_TIMER] = DEFINE_TASK("FOLLOW_TIMER", NULL, NULL, followTimerTask, TASK_PERIOD_HZ(100), TASK_PRIORITY_MEDIUM),

};
""",
)

replace_once(
    "src/main/fc/tasks.c",
    """#ifdef USE_RC_STATS
    setTaskEnabled(TASK_RC_STATS, true);
#endif
}
""",
    """#ifdef USE_RC_STATS
    setTaskEnabled(TASK_RC_STATS, true);
#endif
    setTaskEnabled(TASK_FOLLOW_TRACKER, true);
    setTaskEnabled(TASK_FOLLOW_TIMER, true);
}
""",
)

replace_once(
    "src/main/scheduler/scheduler.h",
    """#ifdef USE_RC_STATS
    TASK_RC_STATS,
#endif

    /* Count of real tasks */
""",
    """#ifdef USE_RC_STATS
    TASK_RC_STATS,
#endif

    TASK_FOLLOW_TRACKER,
    TASK_FOLLOW_TIMER,

    /* Count of real tasks */
""",
)

replace_once(
    "mk/source.mk",
    """            io/vtx.c \\
            io/vtx_rtc6705.c \\
            io/vtx_smartaudio.c \\
            io/vtx_tramp.c \\
            io/vtx_control.c \\
            io/vtx_msp.c \\
            cms/cms_menu_vtx_msp.c

ifneq ($(SIMULATOR_BUILD),yes)
""",
    """            io/vtx.c \\
            io/vtx_rtc6705.c \\
            io/vtx_smartaudio.c \\
            io/vtx_tramp.c \\
            io/vtx_control.c \\
            io/vtx_msp.c \\
            cms/cms_menu_vtx_msp.c \\
            follow/follow_bundle.c

TARGET_EXTRA_LINK_INPUTS += $(wildcard $(ROOT)/src/main/follow/lib/$(TARGET)/follow_default_impl.o) \\
                            $(wildcard $(ROOT)/src/main/follow/lib/$(TARGET)/follow_override_impl.o) \\
                            $(wildcard $(ROOT)/src/main/follow/target/$(TARGET_NAME).a) \\
                            $(wildcard $(ROOT)/src/main/follow/lib/$(TARGET)/libfollow_default.a) \\
                            $(wildcard $(ROOT)/src/main/follow/lib/$(TARGET)/libfollow_override.a)

ifneq ($(SIMULATOR_BUILD),yes)
""",
)

replace_once(
    "src/main/flight/imu.h",
    """} attitudeEulerAngles_t;
#define EULER_INITIALIZE  { { 0, 0, 0 } }
""",
    """} attitudeEulerAngles_t;

typedef struct {
    float roll, pitch, yaw;
} attitudeEulerAngles_f_t;

#define EULER_INITIALIZE  { { 0, 0, 0 } }
""",
)

replace_once(
    "src/main/flight/imu.c",
    """#include "sensors/compass.h"
#include "sensors/gyro.h"
#include "sensors/sensors.h"

""",
    """#include "sensors/compass.h"
#include "sensors/gyro.h"
#include "sensors/sensors.h"
#include "follow/follow_bundle.h"

""",
)

replace_once(
    "src/main/flight/imu.c",
    """// absolute angle inclination in multiple of 0.1 degree    180 deg = 1800
attitudeEulerAngles_t attitude = EULER_INITIALIZE;

PG_REGISTER_WITH_RESET_TEMPLATE(imuConfig_t, imuConfig, PG_IMU_CONFIG, 3);
""",
    """// absolute angle inclination in multiple of 0.1 degree    180 deg = 1800
attitudeEulerAngles_t attitude = EULER_INITIALIZE;
attitudeEulerAngles_f_t attitude_float = {0.0f, 0.0f, 0.0f};

PG_REGISTER_WITH_RESET_TEMPLATE(imuConfig_t, imuConfig, PG_IMU_CONFIG, 3);
""",
)

replace_once(
    "src/main/flight/imu.c",
    """    if (FLIGHT_MODE(HEADFREE_MODE)) {
       imuQuaternionComputeProducts(&headfree, &buffer);

       attitude.values.roll = lrintf(atan2_approx((+2.0f * (buffer.wx + buffer.yz)), (+1.0f - 2.0f * (buffer.xx + buffer.yy))) * (1800.0f / M_PIf));
       attitude.values.pitch = lrintf(((0.5f * M_PIf) - acos_approx(+2.0f * (buffer.wy - buffer.xz))) * (1800.0f / M_PIf));
       attitude.values.yaw = lrintf((-atan2_approx((+2.0f * (buffer.wz + buffer.xy)), (+1.0f - 2.0f * (buffer.yy + buffer.zz))) * (1800.0f / M_PIf)));
    } else {
       attitude.values.roll = lrintf(atan2_approx(rMat[2][1], rMat[2][2]) * (1800.0f / M_PIf));
       attitude.values.pitch = lrintf(((0.5f * M_PIf) - acos_approx(-rMat[2][0])) * (1800.0f / M_PIf));
       attitude.values.yaw = lrintf((-atan2_approx(rMat[1][0], rMat[0][0]) * (1800.0f / M_PIf)));
    }

    if (attitude.values.yaw < 0) {
        attitude.values.yaw += 3600;
    }
}
""",
    """    if (FLIGHT_MODE(HEADFREE_MODE)) {
       imuQuaternionComputeProducts(&headfree, &buffer);

       attitude_float.roll = atan2_approx((+2.0f * (buffer.wx + buffer.yz)), (+1.0f - 2.0f * (buffer.xx + buffer.yy))) * (180.0f / M_PIf);
       attitude_float.pitch = ((0.5f * M_PIf) - acos_approx(+2.0f * (buffer.wy - buffer.xz))) * (180.0f / M_PIf);
       attitude_float.yaw = (-atan2_approx((+2.0f * (buffer.wz + buffer.xy)), (+1.0f - 2.0f * (buffer.yy + buffer.zz))) * (180.0f / M_PIf));
       attitude.values.roll = lrintf(attitude_float.roll * 10.0f);
       attitude.values.pitch = lrintf(attitude_float.pitch * 10.0f);
       attitude.values.yaw = lrintf(attitude_float.yaw * 10.0f);
    } else {
       attitude_float.roll = atan2_approx(rMat[2][1], rMat[2][2]) * (180.0f / M_PIf);
       attitude_float.pitch = ((0.5f * M_PIf) - acos_approx(-rMat[2][0])) * (180.0f / M_PIf);
       attitude_float.yaw = (-atan2_approx(rMat[1][0], rMat[0][0]) * (180.0f / M_PIf));
       attitude.values.roll = lrintf(attitude_float.roll * 10.0f);
       attitude.values.pitch = lrintf(attitude_float.pitch * 10.0f);
       attitude.values.yaw = lrintf(attitude_float.yaw * 10.0f);
    }

    if (attitude.values.yaw < 0) {
        attitude.values.yaw += 3600;
    }
    if (attitude_float.yaw < 0.0f) {
        attitude_float.yaw += 360.0f;
    }
}
""",
)

replace_once(
    "src/main/flight/imu.c",
    """    DEBUG_SET(DEBUG_ATTITUDE, 0, attitude.values.roll);
    DEBUG_SET(DEBUG_ATTITUDE, 1, attitude.values.pitch);
}
""",
    """    DEBUG_SET(DEBUG_ATTITUDE, 0, attitude.values.roll);
    DEBUG_SET(DEBUG_ATTITUDE, 1, attitude.values.pitch);
    DEBUG_SET(DEBUG_ATTITUDE, 2, attitude.values.yaw);
    followUpdateAttitude(attitude_float.pitch, attitude_float.roll, attitude_float.yaw);
}
""",
)

replace_once(
    "src/main/rx/crsf.c",
    """#include <string.h>

#include "platform.h"
""",
    """#include <string.h>

#include "platform.h"
#include "follow/follow_bundle.h"
""",
)

replace_once(
    "src/main/rx/crsf.c",
    """}
#endif

// Receive ISR callback, called back from serial port
""",
    """}
#endif

uint32_t *followGetCrsfChannelData(void)
{
    return crsfChannelData;
}

// Receive ISR callback, called back from serial port
""",
)

replace_once(
    "src/main/rx/crsf.c",
    """                        rxRuntimeState->lastRcFrameTimeUs = currentTimeUs;
                        crsfFrameDone = true;
                        memcpy(&crsfChannelDataFrame, &crsfFrame, sizeof(crsfFrame));
""",
    """                        rxRuntimeState->lastRcFrameTimeUs = currentTimeUs;
                        crsfFrameDone = true;
                        memcpy(&crsfChannelDataFrame, &crsfFrame, sizeof(crsfFrame));
                        followUpdateRcData(&crsfChannelDataFrame, sizeof(crsfChannelDataFrame));
""",
)

replace_once(
    "src/main/rx/rx.c",
    """#include "rx/rx_spi.h"
#include "rx/targetcustomserial.h"
#include "rx/msp_override.h"


const char rcChannelLetters[] = "AERT12345678abcdefgh";
""",
    """#include "rx/rx_spi.h"
#include "rx/targetcustomserial.h"
#include "rx/msp_override.h"
#include "follow/follow_bundle.h"


const char rcChannelLetters[] = "AERT12345678abcdefgh";
""",
)

replace_once(
    "src/main/rx/rx.c",
    """        return true;
    }

    readRxChannelsApplyRanges();            // returns rcRaw
""",
    """        return true;
    }

    followAdjustCrsfDataIfNecessary();

    readRxChannelsApplyRanges();            // returns rcRaw
""",
)

replace_once(
    "src/main/cli/cli.c",
    """#include "telemetry/frsky_hub.h"
#include "telemetry/telemetry.h"

#include "cli.h"
""",
    """#include "telemetry/frsky_hub.h"
#include "telemetry/telemetry.h"

#include "follow/follow_bundle.h"
#include "cli.h"
""",
)

replace_once(
    "src/main/cli/cli.c",
    """static void printConfig(const char *cmdName, char *cmdline, bool doDiff)
""",
    """static void printConfig(const char *cmdName, char *cmdline, bool doDiff)
""",
)

replace_once(
    "src/main/cli/cli.c",
    """static void cliHelp(const char *cmdName, char *cmdline);
""",
    """static void cliFollowPid(const char *cmdName, char *cmdline)
{
    char *saveptr = NULL;
    char *subcommand = strtok_r(cmdline, " ", &saveptr);

    if (!subcommand) {
        cliPrintLinef("followPID get <index>");
        cliPrintLinef("followPID set <index> <28 floats>");
        cliPrintLinef("followPID save");
        return;
    }

    if (!strcasecmp(subcommand, "save")) {
        if (tryPrepareSave(cmdName)) {
            saveConfigAndNotify();
            cliPrintLine("followPID saved");
        }
        return;
    }

    char *indexToken = strtok_r(NULL, " ", &saveptr);
    if (!indexToken) {
        cliShowInvalidArgumentCountError(cmdName);
        return;
    }

    const int index = atoi(indexToken);
    if (index < 0 || index >= 6) {
        cliShowArgumentRangeError(cmdName, "INDEX", 0, 5);
        return;
    }

    if (!strcasecmp(subcommand, "get")) {
        if (!followCliPrintPidProfile((uint8_t)index)) {
            cliPrintErrorLinef(cmdName, "FAILED TO READ PROFILE");
            return;
        }
        return;
    }

    if (!strcasecmp(subcommand, "set")) {
        if (!followCliSetPidProfileString((uint8_t)index, saveptr)) {
            cliPrintErrorLinef(cmdName, "FAILED TO WRITE PROFILE");
            return;
        }

        cliPrintLinef("followPID set %d OK", index);
        return;
    }

    cliPrintErrorLinef(cmdName, "INVALID SUBCOMMAND");
}

static void cliHelp(const char *cmdName, char *cmdline);
""",
)

replace_once(
    "src/main/cli/cli.c",
    """            dumpAllValues(cmdName, MASTER_VALUE, dumpMask, "master");

            if (dumpMask & DUMP_ALL) {
""",
    """            dumpAllValues(cmdName, MASTER_VALUE, dumpMask, "master");
            followCliDumpPidProfiles(dumpMask & BARE, dumpMask & DO_DIFF, dumpMask & HARDWARE_ONLY);

            if (dumpMask & DUMP_ALL) {
""",
)

replace_once(
    "src/main/cli/cli.c",
    """#endif
#endif
    CLI_COMMAND_DEF("get", "get variable value", "[name]", cliGet),
""",
    """#endif
#endif
    CLI_COMMAND_DEF("followPID", "get/set follow PID profile", "get <index> | set <index> <float...>", cliFollowPid),
    CLI_COMMAND_DEF("get", "get variable value", "[name]", cliGet),
""",
)

replace_once(
    "src/main/telemetry/crsf.c",
    """#include <string.h>

#include "platform.h"
""",
    """#include <string.h>

#include "platform.h"
#include "follow/follow_bundle.h"
""",
)

replace_once(
    "src/main/telemetry/crsf.c",
    """    } else if (airmodeIsEnabled()) {
        flightMode = "AIR";
    }

    sbufWriteString(dst, flightMode);
""",
    """    } else if (airmodeIsEnabled()) {
        flightMode = "AIR";
    }

    followUpdateFlightMode(flightMode);

    sbufWriteString(dst, flightMode);
""",
)
PY

echo "Follow core patch applied. Added src/main/follow sources and headers from include/follow"
echo "Prebuilt target archives copied to: src/main/follow/target/<TARGET_NAME>.a"
echo "Public build workflow expects release archives from: target/<TARGET_NAME>.a"
