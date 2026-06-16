# Intentionally pinned to an older base so the demo has real OS-level CVEs
# for Microsoft Defender for Containers to find and Copacetic to patch.
# In production you would track the latest patched base via Dependabot.
FROM python:3.9-slim-bullseye

WORKDIR /app
COPY app.py .

# Patch Python-layer CVEs (setuptools/wheel/pip) that Copacetic cannot fix.
# Copa only remediates OS-level (apt/dpkg) packages, so these application-layer
# CVEs must be fixed in the image itself (the Dependabot-style responsibility of
# the image owner). Retried so a transient PyPI blip can't fail docker build;
# --root-user-action=ignore silences the benign root warning. The outdated OS
# packages from the pinned bullseye base are deliberately left for Defender to
# flag and Copacetic to patch at build time.
RUN for i in 1 2 3; do \
      pip install --no-cache-dir --upgrade --root-user-action=ignore \
        "pip>=25.3" "setuptools>=78.1.1" "wheel>=0.46.2" && break || \
      { echo "pip upgrade attempt $i failed; retrying in 5s"; sleep 5; }; \
    done

ENV PORT=8080 APP_VERSION=1.0.0
EXPOSE 8080

# Run as non-root
RUN useradd -u 10001 -m appuser
USER 10001

ENTRYPOINT ["python", "app.py"]
