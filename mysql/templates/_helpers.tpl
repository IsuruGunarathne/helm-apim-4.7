{{/*
Chart fullname — defaults to the release name.
Install with: helm install mysql ./mysql/ -n apim
*/}}
{{- define "wso2am-mysql.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "wso2am-mysql.labels" -}}
app.kubernetes.io/name: {{ include "wso2am-mysql.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "wso2am-mysql.selectorLabels" -}}
app.kubernetes.io/name: {{ include "wso2am-mysql.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
