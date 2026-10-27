ARG PYTHON_IMAGE=python:3-alpine
FROM ${PYTHON_IMAGE}

COPY subconfig-api/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --requirement /tmp/requirements.txt

CMD ["python", "/app/subconfig-api.py"]
