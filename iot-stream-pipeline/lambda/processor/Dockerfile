# AWS公式のLambda Python 3.12 arm64ベースイメージを使用する
# 理由: Graviton2(arm64)はx86_64比でコスト約20%削減かつ高性能
FROM public.ecr.aws/lambda/python:3.12-arm64

# 依存関係を先にコピーしてキャッシュを活かす
# 理由: app.pyの変更時にpip installを再実行しないようにする
COPY requirements.txt ${LAMBDA_TASK_ROOT}/
RUN pip install --no-cache-dir -r ${LAMBDA_TASK_ROOT}/requirements.txt

COPY app.py ${LAMBDA_TASK_ROOT}/

CMD ["app.handler"]
