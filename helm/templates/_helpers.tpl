{{/*
Expand the name of the chart.
*/}}
{{- define "nvidia-nim.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "nvidia-nim.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "nvidia-nim.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "nvidia-nim.labels" -}}
helm.sh/chart: {{ include "nvidia-nim.chart" . }}
{{ include "nvidia-nim.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "nvidia-nim.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nvidia-nim.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Name of the Opaque Secret that holds NGC_API_KEY for the container.
Derived from the release fullname so releases never collide.
*/}}
{{- define "nvidia-nim.ngcApiSecretName" -}}
{{- printf "%s-ngc-api" (include "nvidia-nim.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Name of the dockerconfigjson Secret used to pull the NIM image from nvcr.io.
*/}}
{{- define "nvidia-nim.imagePullSecretName" -}}
{{- printf "%s-ngc-registry" (include "nvidia-nim.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "nvidia-nim.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "nvidia-nim.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

