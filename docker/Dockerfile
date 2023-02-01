FROM python:3.9.16-slim

ENV DASH_DEBUG_MODE True

COPY requirements.txt .

RUN pip install --upgrade pip && \
  pip install -r requirements.txt


# COPY . /work
# WORKDIR /work

#ENTRYPOINT ["python"]
#CMD ["app.py"]