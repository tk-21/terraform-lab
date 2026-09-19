{{/*
共通ヘルパーテンプレート
*/}}

{{/* チャート名 */}}
{{- define "gpu-inference-operator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* フルネーム: release名 + chart名 */}}
{{- define "gpu-inference-operator.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* Chart ラベル */}}
{{- define "gpu-inference-operator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* 共通ラベル */}}
{{- define "gpu-inference-operator.labels" -}}
helm.sh/chart: {{ include "gpu-inference-operator.chart" . }}
{{ include "gpu-inference-operator.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* セレクターラベル */}}
{{- define "gpu-inference-operator.selectorLabels" -}}
app.kubernetes.io/name: {{ include "gpu-inference-operator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* ServiceAccount名 */}}
{{- define "gpu-inference-operator.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "gpu-inference-operator.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
