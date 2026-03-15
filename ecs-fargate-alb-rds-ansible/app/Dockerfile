FROM node:20-alpine

WORKDIR /app
COPY src/package.json /app/package.json
RUN npm install --omit=dev

COPY src /app
EXPOSE 8080
CMD ["node", "index.js"]
