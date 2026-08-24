FROM node:20-alpine

RUN npm -g --production install coffeescript && \
    apk --no-cache add lame curl && \
    rm -rf /tmp/* /var/cache/apk/*

WORKDIR /app

ADD app /app

RUN npm install

EXPOSE 8000

CMD ["coffee", "app.coffee"]
