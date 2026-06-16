#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSET_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HEADER_ROOT="$ASSET_ROOT/include"
SOURCE_ROOT="$ASSET_ROOT/src/main/follow"
CONFIG_ROOT="$ASSET_ROOT/src/config"
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

find "$SOURCE_ROOT" -type f -name '*.c' \
  ! -name 'follow_default_impl.c' \
  ! -name 'follow_override_impl.c' \
  ! -name 'follow_override_impl_template.c' | while read -r src; do
  rel="${src#$SOURCE_ROOT/}"
  dst="$ROOT_DIR/src/main/follow/$rel"
  mkdir -p "$(dirname "$dst")"
  install_if_needed 0644 "$src" "$dst"
done

if [ -d "$CONFIG_ROOT/configs" ]; then
  find "$CONFIG_ROOT/configs" -type f | while read -r src; do
    rel="${src#$CONFIG_ROOT/}"
    dst="$ROOT_DIR/src/config/$rel"
    mkdir -p "$(dirname "$dst")"
    install_if_needed 0644 "$src" "$dst"
  done
fi

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
        return
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
    """uint8_t systemState = SYSTEM_STATE_INITIALISING;

""",
    """uint8_t systemState = SYSTEM_STATE_INITIALISING;

static bool servoOutputsConfigured(void)
{
#ifdef USE_SERVOS
    for (uint8_t i = 0; i < MAX_SUPPORTED_SERVOS; i++) {
        if (servoConfig()->dev.ioTags[i]) {
            return true;
        }
    }
#endif

    return false;
}

""",
)

replace_once(
    "src/main/fc/init.c",
    """    if (isMixerUsingServos()) {
""",
    """    if (isMixerUsingServos() || servoOutputsConfigured()) {
""",
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
            follow/follow_bundle.c \\
            follow/follow_gyrocal.c \\
            follow/modes/follow_mode.c

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
    "src/main/rx/crsf.h",
    """#include "rx/crsf_protocol.h"
""",
    """#include "rx/crsf_protocol.h"

#ifndef RC_RANGE_MIN
#define RC_RANGE_MIN 172
#define RC_RANGE_MAX 1811
#define RC_RANGE_TERM 992
#define RC_RANGE_WIDE 1639
#define RC_RANGE_TH_MIN 271
#define RC_RANGE_TH_MAX 1791
#define RC_RANGE_TH_WIDE 1520
#endif
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
    "src/main/rx/rx.c",
    """#endif

    DEBUG_SET(DEBUG_FAILSAFE, 1, rxSignalReceived);
    DEBUG_SET(DEBUG_RX_SIGNAL_LOSS, 0, rxSignalReceived);
}
""".replace("#endif\n\n", "#endif\n    \n"),
    """#endif

    if (followCrsfOverridePending()) {
        rxDataProcessingRequired = true;
    }

    DEBUG_SET(DEBUG_FAILSAFE, 1, rxSignalReceived);
    DEBUG_SET(DEBUG_RX_SIGNAL_LOSS, 0, rxSignalReceived);
}
""",
)

replace_once(
    "src/main/sensors/gyro.h",
    """#pragma once

#include "common/axis.h"
""",
    """#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "common/axis.h"
""",
)

replace_once(
    "src/main/sensors/gyro.h",
    """#include "pg/pg.h"
""",
    """#include "pg/pg.h"

#include "follow/follow_gyrocal.h"
""",
)

replace_once(
    "src/main/sensors/gyro.h",
    """    uint8_t simplified_gyro_filter;
    uint8_t simplified_gyro_filter_multiplier;
} gyroConfig_t;
""",
    """    uint8_t simplified_gyro_filter;
    uint8_t simplified_gyro_filter_multiplier;
    gyroCalibrationConfig_t gyroCalibration[GYRO_CALIBRATION_CONFIG_COUNT];
} gyroConfig_t;
""",
)

replace_once(
    "src/main/sensors/gyro.h",
    """void gyroStartCalibration(bool isFirstArmingCalibration);
bool isFirstArmingGyroCalibrationRunning(void);
""",
    """void gyroStartCalibration(bool isFirstArmingCalibration);
bool gyroSaveCalibration(void);
void gyroResetSavedCalibration(void);
void gyroApplySavedCalibration(gyroSensor_t *gyroSensor, uint8_t gyroIndex);
bool isFirstArmingGyroCalibrationRunning(void);
""",
)

replace_once(
    "src/main/sensors/gyro.c",
    """PG_REGISTER_WITH_RESET_FN(gyroConfig_t, gyroConfig, PG_GYRO_CONFIG, 9);
""",
    """PG_REGISTER_WITH_RESET_FN(gyroConfig_t, gyroConfig, PG_GYRO_CONFIG, 10);
""",
)

replace_once(
    "src/main/sensors/gyro.c",
    """    gyroConfig->gyro_lpf1_dyn_expo = 5;
    gyroConfig->simplified_gyro_filter = true;
    gyroConfig->simplified_gyro_filter_multiplier = SIMPLIFIED_TUNING_DEFAULT;
}
""",
    """    gyroConfig->gyro_lpf1_dyn_expo = 5;
    gyroConfig->simplified_gyro_filter = true;
    gyroConfig->simplified_gyro_filter_multiplier = SIMPLIFIED_TUNING_DEFAULT;
    for (int gyroIndex = 0; gyroIndex < GYRO_CALIBRATION_CONFIG_COUNT; gyroIndex++) {
        for (int valueIndex = 0; valueIndex < GYRO_CALIBRATION_CONFIG_VALUE_COUNT; valueIndex++) {
            gyroConfig->gyroCalibration[gyroIndex].raw[valueIndex] = 0;
        }
    }
}
""",
)

replace_once(
    "src/main/sensors/gyro_init.c",
    """        gyroInitSensor(&gyro.gyroSensor2, gyroDeviceConfig(1));
        gyro.gyroHasOverflowProtection = gyro.gyroHasOverflowProtection && gyro.gyroSensor2.gyroDev.gyroHasOverflowProtection;
""",
    """        gyroInitSensor(&gyro.gyroSensor2, gyroDeviceConfig(1));
        gyroApplySavedCalibration(&gyro.gyroSensor2, GYRO_CONFIG_USE_GYRO_2);
        gyro.gyroHasOverflowProtection = gyro.gyroHasOverflowProtection && gyro.gyroSensor2.gyroDev.gyroHasOverflowProtection;
""",
)

replace_once(
    "src/main/sensors/gyro_init.c",
    """        gyroInitSensor(&gyro.gyroSensor1, gyroDeviceConfig(0));
        gyro.gyroHasOverflowProtection =  gyro.gyroHasOverflowProtection && gyro.gyroSensor1.gyroDev.gyroHasOverflowProtection;
""",
    """        gyroInitSensor(&gyro.gyroSensor1, gyroDeviceConfig(0));
        gyroApplySavedCalibration(&gyro.gyroSensor1, GYRO_CONFIG_USE_GYRO_1);
        gyro.gyroHasOverflowProtection =  gyro.gyroHasOverflowProtection && gyro.gyroSensor1.gyroDev.gyroHasOverflowProtection;
""",
)

replace_once(
    "src/main/cli/settings.c",
    """    { "gyro_calib_duration",        VAR_UINT16 | MASTER_VALUE, .config.minmaxUnsigned = { 50,  3000 }, PG_GYRO_CONFIG, offsetof(gyroConfig_t, gyroCalibrationDuration) },
    { "gyro_calib_noise_limit",     VAR_UINT8  | MASTER_VALUE, .config.minmaxUnsigned = { 0,  200 }, PG_GYRO_CONFIG, offsetof(gyroConfig_t, gyroMovementCalibrationThreshold) },
    { "gyro_offset_yaw",            VAR_INT16  | MASTER_VALUE, .config.minmax = { -1000, 1000 }, PG_GYRO_CONFIG, offsetof(gyroConfig_t, gyro_offset_yaw) },
""",
    """    { "gyro_calib_duration",        VAR_UINT16 | MASTER_VALUE, .config.minmaxUnsigned = { 50,  3000 }, PG_GYRO_CONFIG, offsetof(gyroConfig_t, gyroCalibrationDuration) },
    { "gyro_calib_noise_limit",     VAR_UINT8  | MASTER_VALUE, .config.minmaxUnsigned = { 0,  200 }, PG_GYRO_CONFIG, offsetof(gyroConfig_t, gyroMovementCalibrationThreshold) },
    { "gyro_offset_yaw",            VAR_INT16  | MASTER_VALUE, .config.minmax = { -1000, 1000 }, PG_GYRO_CONFIG, offsetof(gyroConfig_t, gyro_offset_yaw) },
    { "gyro_1_calibration",         VAR_INT32  | MASTER_VALUE | MODE_ARRAY, .config.array.length = GYRO_CALIBRATION_CONFIG_VALUE_COUNT, PG_GYRO_CONFIG, offsetof(gyroConfig_t, gyroCalibration) },
#ifdef USE_MULTI_GYRO
    { "gyro_2_calibration",         VAR_INT32  | MASTER_VALUE | MODE_ARRAY, .config.array.length = GYRO_CALIBRATION_CONFIG_VALUE_COUNT, PG_GYRO_CONFIG, offsetof(gyroConfig_t, gyroCalibration) + sizeof(gyroCalibrationConfig_t) },
#endif
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
#include "follow/follow_gyrocal.h"
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
    CLI_COMMAND_DEF("gyrocal", "calibrate/save gyro zero offset", "status | start | save | show | reset", followCliGyroCal),
    CLI_COMMAND_DEF("followPID", "get/set follow PID profile", "get <index> | set <index> <float...>", cliFollowPid),
    CLI_COMMAND_DEF("get", "get variable value", "[name]", cliGet),
""",
)

replace_once(
    "src/main/msp/msp.c",
    """    case MSP_BUILD_INFO:
        sbufWriteData(dst, buildDate, BUILD_DATE_LENGTH);
        sbufWriteData(dst, buildTime, BUILD_TIME_LENGTH);
        sbufWriteData(dst, shortGitRevision, GIT_SHORT_REVISION_LENGTH);
        // Added in API version 1.46
        sbufWriteBuildInfoFlags(dst);
        break;
""",
    """    case MSP_BUILD_INFO: {
        sbufWriteData(dst, buildDate, BUILD_DATE_LENGTH);
        sbufWriteData(dst, buildTime, BUILD_TIME_LENGTH);
        char shortGitRevisionOutput[GIT_SHORT_REVISION_LENGTH] = { 0 };
        for (int i = 0; i < GIT_SHORT_REVISION_LENGTH && shortGitRevision[i]; i++) {
            shortGitRevisionOutput[i] = shortGitRevision[i];
        }
        sbufWriteData(dst, shortGitRevisionOutput, sizeof(shortGitRevisionOutput));
        // Added in API version 1.46
        sbufWriteBuildInfoFlags(dst);
        break;
    }
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
