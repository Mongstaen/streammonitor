FROM python:3.13-alpine
COPY monitor_ntfy.py /app/monitor_ntfy.py
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
ENTRYPOINT ["/app/entrypoint.sh"]
