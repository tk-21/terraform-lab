#\!/usr/bin/env python3
import os
import requests
from flask import Flask, jsonify

app = Flask(__name__)


def get_imdsv2_token() -> str:
    response = requests.put(
        "http://169.254.169.254/latest/api/token",
        headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"},
        timeout=2,
    )
    return response.text


def get_metadata(path: str) -> str:
    try:
        token = get_imdsv2_token()
        response = requests.get(
            f"http://169.254.169.254/latest/meta-data/{path}",
            headers={"X-aws-ec2-metadata-token": token},
            timeout=2,
        )
        return response.text
    except Exception:
        return "unknown"


@app.route("/")
def index():
    return jsonify({"message": "terraform-ansible-aws-platform", "status": "ok"})


@app.route("/api/health")
def health():
    return jsonify({
        "status": "healthy",
        "host": os.uname().nodename,
    })


@app.route("/api/info")
def info():
    return jsonify({
        "instance_id":        get_metadata("instance-id"),
        "availability_zone":  get_metadata("placement/availability-zone"),
        "instance_type":      get_metadata("instance-type"),
        "local_ipv4":         get_metadata("local-ipv4"),
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
