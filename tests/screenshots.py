"""Generate README images from zdiff's real buffer with a pinned Tokyo Night theme."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".artifacts"
THEME = BUILD / "tokyonight.nvim"
THEME_REVISION = "cdc07ac78467a233fd62c493de29a17e0cf2b2b6"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, cwd=ROOT, **kwargs)


def main():
    nvim = shutil.which(os.environ.get("NVIM_BIN", "nvim"))
    chromium = shutil.which(os.environ.get("CHROMIUM_BIN", "chromium"))
    if not nvim or not chromium:
        raise SystemExit(
            "Screenshots require Neovim and Chromium (or set NVIM_BIN and CHROMIUM_BIN)."
        )

    BUILD.mkdir(exist_ok=True)
    if not THEME.exists():
        run("git", "init", "-q", str(THEME))
    revision = subprocess.run(
        ["git", "-C", str(THEME), "rev-parse", "--verify", "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    )
    if revision.stdout.strip() != THEME_REVISION:
        run(
            "git",
            "-C",
            str(THEME),
            "fetch",
            "--depth=1",
            "https://github.com/folke/tokyonight.nvim.git",
            THEME_REVISION,
        )
        run("git", "-C", str(THEME), "checkout", "--quiet", "--detach", "FETCH_HEAD")

    env = dict(
        os.environ,
        XDG_CACHE_HOME=str(BUILD / "cache"),
        XDG_STATE_HOME=str(BUILD / "state"),
        NVIM_LOG_FILE=str(BUILD / "nvim.log"),
    )
    with tempfile.TemporaryDirectory(prefix="screenshots-", dir=BUILD) as temporary:
        output = Path(temporary)
        run(
            nvim,
            "--headless",
            "-u",
            "NONE",
            "-i",
            "NONE",
            "-l",
            "tests/screenshots.lua",
            str(THEME),
            str(output),
            env=env,
        )
        images = ROOT / "doc" / "images"
        images.mkdir(exist_ok=True)
        for scene, height in [("overview", 264), ("expanded", 936)]:
            run(
                chromium,
                "--headless",
                "--disable-gpu",
                "--hide-scrollbars",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-background-networking",
                "--user-data-dir=" + str(output / "chromium"),
                "--window-size=1040," + str(height),
                "--screenshot=" + str(images / (scene + ".png")),
                (output / (scene + ".html")).as_uri(),
                env=env,
                capture_output=True,
            )
            print("Saved", images / (scene + ".png"))


if __name__ == "__main__":
    main()
