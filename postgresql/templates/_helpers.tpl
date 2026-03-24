{{/*
Chart fullname — defaults to the release name.
Install with: helm install postgresql ./postgresql/ -n apim
*/}}
{{- define "wso2am-postgresql.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "wso2am-postgresql.labels" -}}
app.kubernetes.io/name: {{ include "wso2am-postgresql.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "wso2am-postgresql.selectorLabels" -}}
app.kubernetes.io/name: {{ include "wso2am-postgresql.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
