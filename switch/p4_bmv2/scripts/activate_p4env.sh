#!/bin/bash
# 加载 p4c / simple_switch 环境（p4dev 虚拟机或本机安装）
# 用法: source scripts/activate_p4env.sh（由 start_switch.sh 调用）
# 详见 switch/LEARNING_zh.md、DEPLOY_UBUNTU.md

_p4_try_source() {
  local f=$1
  if [[ -f "$f" ]]; then
    # shellcheck disable=SC1090
    source "$f"
    return 0
  fi
  return 1
}

if command -v p4c >/dev/null 2>&1 && command -v simple_switch >/dev/null 2>&1; then
  return 0 2>/dev/null || exit 0
fi

# Common p4dev / P4 tutorial paths
for setup in \
  "$HOME/p4setup.bash" \
  "$HOME/tutorials/p4setup.bash" \
  "$HOME/p4/p4setup.sh" \
  "$HOME/p4/p4setup.bash" \
  "/opt/p4/p4setup.sh" \
  "/opt/p4/p4setup.bash" \
  "$HOME/p4dev/p4setup.sh" \
  "/etc/profile.d/p4.sh" \
  ; do
  _p4_try_source "$setup" && break
done

# p4dev tutorials build tree (e.g. ~/tutorials/p4c-stable/build/p4c)
for bindir in \
  "$HOME/tutorials/p4c-stable/build" \
  "$HOME/tutorials/p4c/build" \
  ; do
  if [[ -x "$bindir/p4c" ]]; then
    export P4C="$bindir/p4c"
    export PATH="$bindir:/usr/local/bin:${PATH}"
    break
  fi
done

export PATH="/usr/local/bin:/usr/bin:${HOME}/.local/bin:${PATH}"

# p4c-bm2 sometimes installed as alternative name
if ! command -v p4c >/dev/null 2>&1 && command -v p4c-bm2 >/dev/null 2>&1; then
  export P4C=p4c-bm2
fi

if command -v p4c >/dev/null 2>&1; then
  echo "p4c: $(command -v p4c)"
  command -v simple_switch >/dev/null && echo "simple_switch: $(command -v simple_switch)"
  return 0 2>/dev/null || exit 0
fi

echo "ERROR: p4c not found in PATH."
echo ""
echo "Search on this machine:"
echo "  find /usr /opt \$HOME -name 'p4c' -type f 2>/dev/null | head"
echo ""
echo "If using p4dev, source its setup, e.g.:"
echo "  source ~/p4/p4setup.sh"
echo "Then: bash scripts/start_switch.sh"
echo ""
echo "Or set P4C explicitly:"
echo "  export P4C=/path/to/p4c"
echo "  bash scripts/start_switch.sh"
return 1 2>/dev/null || exit 1
