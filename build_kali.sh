#!/usr/bin/env bash
set -e

# ==============================================================================
# YTKACE + Native VOT: Automated Build & Acceleration Script for Kali / Debian
# ==============================================================================

BOLD="\033[1m"
GREEN="\033[0;32m"
CYAN="\033[0;36m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
RESET="\033[0m"

echo -e "${BOLD}${CYAN}=== YTKACE Native VOT Builder for Kali Linux ===${RESET}\n"

# 1. Check and install dependencies
echo -e "${YELLOW}[1/5] Проверка системных зависимостей (APT)...${RESET}"
MISSING_PKGS=()
for pkg in build-essential make clang git curl wget xz-utils zip unzip python3 ccache; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo -e "Установка недостающих пакетов: ${MISSING_PKGS[*]}..."
    sudo apt-get update -y
    sudo apt-get install -y "${MISSING_PKGS[@]}"
else
    echo -e "${GREEN}Все необходимые системные пакеты уже установлены.${RESET}"
fi

# Установка ldid при отсутствии в системе
if ! command -v ldid >/dev/null 2>&1; then
    echo -e "${YELLOW}Загрузка ldid для Linux...${RESET}"
    sudo wget -qO /usr/local/bin/ldid https://github.com/ProcursusTeam/ldid/releases/latest/download/ldid_linux_x86_64 2>/dev/null || \
    sudo curl -fsSL -o /usr/local/bin/ldid https://github.com/ProcursusTeam/ldid/releases/latest/download/ldid_linux_x86_64
    sudo chmod +x /usr/local/bin/ldid 2>/dev/null || true
fi

# Theos Linux Darwin toolchain requires libtinfo.so.5 / libncurses.so.5
if [ ! -f /usr/lib/x86_64-linux-gnu/libtinfo.so.5 ] && [ -f /usr/lib/x86_64-linux-gnu/libtinfo.so.6 ]; then
    echo "Настройка совместимости тулчейна (libtinfo.so.5 -> libtinfo.so.6)..."
    sudo ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.5
    sudo ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6 /usr/lib/x86_64-linux-gnu/libncurses.so.5 2>/dev/null || true
    sudo ldconfig 2>/dev/null || true
fi

# 2. Setup RootHide Theos
echo -e "\n${YELLOW}[2/5] Проверка и настройка Theos...${RESET}"
export THEOS="${THEOS:-$HOME/theos}"
if [ ! -d "$THEOS" ]; then
    echo "Установка RootHide Theos в $THEOS..."
    CI=true bash -c "$(curl -fsSL https://raw.githubusercontent.com/roothide/theos/master/bin/install-theos)" <<< "n"
else
    echo -e "${GREEN}Theos найден в $THEOS.${RESET}"
fi

# 3. Setup iOS SDK
echo -e "\n${YELLOW}[3/5] Проверка iOS SDK в Theos...${RESET}"
mkdir -p "$THEOS/sdks"
SDK_TARGET="iPhoneOS16.5.sdk"
if [ ! -d "$THEOS/sdks/$SDK_TARGET" ]; then
    echo "Загрузка iOS 16.5 SDK от Theos community..."
    curl -fsSL "https://github.com/theos/sdks/releases/latest/download/${SDK_TARGET}.tar.xz" -o "/tmp/${SDK_TARGET}.tar.xz"
    tar -xJf "/tmp/${SDK_TARGET}.tar.xz" -C "$THEOS/sdks"
    rm -f "/tmp/${SDK_TARGET}.tar.xz"
    echo -e "${GREEN}SDK $SDK_TARGET успешно установлен.${RESET}"
else
    echo -e "${GREEN}iOS SDK $SDK_TARGET готов к работе.${RESET}"
fi

# 4. Fast compilation with ccache and multi-core acceleration
echo -e "\n${YELLOW}[4/5] Компиляция YTKACE с нативным Voice-Over Translation...${RESET}"
NCPU=$(nproc 2>/dev/null || echo 4)
echo -e "Используется ядер процессора: ${BOLD}$NCPU${RESET} (многопоточная сборка)"

# Acceleration settings
export CCACHE_DIR="$HOME/.ccache"
ccache -M 5G >/dev/null 2>&1 || true

make clean
make -j"$NCPU" package \
    FINALPACKAGE=1 \
    THEOS_PACKAGE_SCHEME=rootless \
    DISABLE_ROOTLESS_COMPAT_WARNING=1

DEB_FILE=$(ls -t packages/*.deb 2>/dev/null | head -n1)
if [ -z "$DEB_FILE" ] || [ ! -f "$DEB_FILE" ]; then
    echo -e "${RED}Ошибка: .deb пакет не был собран!${RESET}"
    exit 1
fi
echo -e "${GREEN}Пакет успешно скомпилирован: $DEB_FILE${RESET}"

# 5. Pack into IPA (if IPA base is found)
echo -e "\n${YELLOW}[5/5] Упаковка готового IPA...${RESET}"
INPUT_IPA="${1:-}"
if [ -z "$INPUT_IPA" ]; then
    # Look for any .ipa in current directory (case-insensitive)
    INPUT_IPA=$(find . -maxdepth 1 -type f -iname "*.ipa" ! -iname "*VOT*" | sed 's|^\./||' | head -n1 || true)
fi

if [ -n "$INPUT_IPA" ] && [ -f "$INPUT_IPA" ]; then
    echo "Обнаружен базовый IPA: $INPUT_IPA"
    mkdir -p /tmp/ytkace_deb_unpack
    dpkg-deb -x "$DEB_FILE" /tmp/ytkace_deb_unpack

    DYLIB_PATH=$(find /tmp/ytkace_deb_unpack -name "YTKACE.dylib" | head -n1)
    OUTPUT_IPA="YTKACE_1.1.3_YouTube_VOT_kali.ipa"

    chmod +x Scripts/*.sh Tools/*.sh 2>/dev/null || true
    echo "Запуск sideload-repack.sh..."
    bash Scripts/sideload-repack.sh "$INPUT_IPA" "$DYLIB_PATH" "$OUTPUT_IPA"
    rm -rf /tmp/ytkace_deb_unpack

    echo -e "\n${BOLD}${GREEN}================================================================${RESET}"
    echo -e "${BOLD}${GREEN}ГОТОВО! Финальный IPA успешно собран:${RESET}"
    echo -e "${BOLD}${CYAN}$PWD/$OUTPUT_IPA${RESET}"
    echo -e "${BOLD}${GREEN}================================================================${RESET}"
else
    echo -e "${YELLOW}Базовый YouTube IPA не найден в текущей папке.${RESET}"
    echo -e "Чтобы автоматически собрать IPA, скопируйте в эту папку YouTube.ipa и выполните:"
    echo -e "  ${CYAN}./build_kali.sh YouTube.ipa${RESET}"
    echo -e "\nЛибо используйте готовый DEB-пакет: ${CYAN}$DEB_FILE${RESET}"
fi
