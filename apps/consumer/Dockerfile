FROM node:20-alpine

WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci || npm install

COPY src ./src

ENV METRICS_PORT=9102
EXPOSE 9102

CMD ["npm","start"]
