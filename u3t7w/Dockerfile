ARG PYTHON_IMAGE=python:3.13-slim-bookworm
FROM ${PYTHON_IMAGE}

COPY subconfig-api/requirements.txt /tmp/requirements.txt
# Use upstream wheels instead of compiling Python build dependencies on a small VPS.
RUN pip install --no-cache-dir --only-binary=:all: --requirement /tmp/requirements.txt

CMD ["python", "/app/subconfig-api.py"]
