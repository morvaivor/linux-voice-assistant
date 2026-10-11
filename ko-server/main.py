"""FastAPI server that cross-builds the ReSpeaker 4-Mic HAT kernel
module (seeed-voicecard, AC108 codec) against the matching Raspberry
Pi kernel branch and serves the resulting .ko files.

Endpoints:
    GET  /health                        liveness + toolchain presence
    GET  /modules                       list of prebuilt .ko files
    GET  /modules/{version}.ko          download a built module
    POST /build                         queue a build for a kernel version
    GET  /builds/{job_id}               build job status
"""

import hashlib
import json
import os
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

BASE_DIR = Path(os.environ.get("KO_BASE", "/opt/ko"))
KERNEL_SRC = Path(os.environ.get("KERNEL_SRC", "/opt/kern618"))
SEEED_SRC = Path(os.environ.get("SEEED_SRC", "/opt/seed-v614"))
OUT_DIR = BASE_DIR / "modules"
JOBS_DIR = BASE_DIR / "jobs"
BUILD_SCRIPT = Path(os.environ.get("BUILD_SCRIPT", "/ko-server/build_module.sh"))

MODULES = ("snd-soc-ac108.ko", "snd-soc-seeed-voicecard.ko", "snd-soc-wm8960.ko")
# kernel release such as "6.18.50+rpt-rpi-v8" (note the '+')
VERSION_RE = r"^\d+\.\d+\.\d+[-+.a-zA-Z0-9]*$"

app = FastAPI(title="seeed-voicecard .ko build server", version="1.0.0")


class BuildRequest(BaseModel):
    kernel_version: str = Field(pattern=VERSION_RE)
    force: bool = False


class BuildStatus(BaseModel):
    job_id: str
    kernel_version: str
    status: str
    started_at: datetime
    finished_at: datetime | None = None
    artifact: str | None = None
    log_tail: str = ""


def _toolchain() -> dict[str, bool]:
    return {
        "cross-compiler": shutil.which("aarch64-linux-gnu-gcc") is not None,
        "kernel-source": KERNEL_SRC.is_dir(),
        "seeed-source": SEEED_SRC.is_dir(),
        "build-script": BUILD_SCRIPT.is_file(),
    }


@app.on_event("startup")
def startup() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    JOBS_DIR.mkdir(parents=True, exist_ok=True)


@app.get("/health")
def health() -> dict:
    return {"ok": True, "toolchain": _toolchain()}


@app.get("/modules")
def list_modules() -> list[dict]:
    out = []
    for vdir in sorted(OUT_DIR.iterdir()):
        if not vdir.is_dir():
            continue
        for f in sorted(vdir.glob("*.ko")):
            out.append({
                "version": vdir.name,
                "filename": f.name,
                "size": f.stat().st_size,
                "sha256": hashlib.sha256(f.read_bytes()).hexdigest(),
            })
    return out


@app.get("/modules/{version}.ko")
def download_card_module(version: str) -> FileResponse:
    return _download(version, "snd-soc-seeed-voicecard.ko")


@app.get("/modules/{version}/{filename}")
def download_module(version: str, filename: str) -> FileResponse:
    return _download(version, filename)


def _download(version: str, filename: str) -> FileResponse:
    safe_v = "".join(c for c in version if c.isalnum() or c in ".+-")
    safe_f = "".join(c for c in filename if c.isalnum() or c in ".-")
    if not safe_f.endswith(".ko"):
        raise HTTPException(400, "only .ko files are served")
    path = OUT_DIR / safe_v / safe_f
    if not path.is_file():
        raise HTTPException(404, f"no module {safe_v}/{safe_f}")
    return FileResponse(path, filename=path.name, media_type="application/octet-stream")


@app.post("/build", response_model=BuildStatus)
def build(req: BuildRequest) -> BuildStatus:
    t = _toolchain()
    if not all(t.values()):
        raise HTTPException(503, f"toolchain not ready: {t}")

    built = (OUT_DIR / req.kernel_version)
    have_all = built.is_dir() and all((built / m).is_file() for m in MODULES)
    if have_all and not req.force:
        job_id = req.kernel_version
        return BuildStatus(
            job_id=job_id, kernel_version=req.kernel_version, status="cached",
            started_at=datetime.now(timezone.utc),
            artifact=", ".join(MODULES),
        )

    job_id = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    job_dir = JOBS_DIR / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    (job_dir / "status.json").write_text(
        json.dumps({"job_id": job_id, "kernel_version": req.kernel_version,
                    "status": "queued", "started_at": datetime.now(timezone.utc).isoformat()})
    )
    subprocess.Popen([
        "bash", str(BUILD_SCRIPT),
        req.kernel_version, str(KERNEL_SRC), str(SEEED_SRC), str(OUT_DIR),
    ], stdout=(job_dir / "build.log").open("w"), stderr=subprocess.STDOUT)
    return BuildStatus(job_id=job_id, kernel_version=req.kernel_version,
                       status="queued", started_at=datetime.now(timezone.utc))


@app.get("/builds/{job_id}", response_model=BuildStatus)
def build_status(job_id: str) -> BuildStatus:
    job_dir = JOBS_DIR / job_id
    if not job_dir.is_dir():
        raise HTTPException(404, "unknown job")
    st = json.loads((job_dir / "status.json").read_text())
    kver = st["kernel_version"]
    vdir = OUT_DIR / kver
    have_all = vdir.is_dir() and all((vdir / m).is_file() for m in MODULES)
    if st["status"] == "queued" and have_all:
        st["status"] = "done"
        st["finished_at"] = datetime.now(timezone.utc)
        st["artifact"] = ", ".join(MODULES)
        (job_dir / "status.json").write_text(json.dumps(st))
    elif st["status"] == "queued":
        log = (job_dir / "build.log").read_text(errors="replace") if (job_dir / "build.log").exists() else ""
        if f"OK {kver}" in log:
            st["status"] = "done"
            st["finished_at"] = datetime.now(timezone.utc)
            st["artifact"] = ", ".join(MODULES) if have_all else None
        elif "Error" in log or "error:" in log:
            st["status"] = "failed"
            st["finished_at"] = datetime.now(timezone.utc)
        st["log_tail"] = log[-2000:]
    return BuildStatus(**st)
