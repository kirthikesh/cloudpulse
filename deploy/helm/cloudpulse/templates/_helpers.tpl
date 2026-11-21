{{- define "cloudpulse.name" -}}cloudpulse{{- end -}}

{{- define "cloudpulse.labels" -}}
app.kubernetes.io/name: {{ include "cloudpulse.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
cloudpulse/env: {{ .Values.env }}
{{- end -}}

{{- define "cloudpulse.selector" -}}
app.kubernetes.io/name: {{ include "cloudpulse.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "cloudpulse.image" -}}
{{- required "image.repository is required" .Values.image.repository }}:{{ required "image.tag is required" .Values.image.tag }}
{{- end -}}

{{/* Pod-level security that satisfies the "restricted" Pod Security Standard */}}
{{- define "cloudpulse.podSecurity" -}}
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
fsGroup: 10001
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "cloudpulse.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end -}}

{{- define "cloudpulse.env" -}}
- name: APP_ENV
  value: {{ .Values.env | quote }}
- name: AWS_REGION
  value: {{ .Values.aws.region | quote }}
- name: TABLE_NAME
  value: {{ .Values.aws.tableName | default (printf "cloudpulse-%s" .Values.env) | quote }}
- name: IMAGE_TAG
  value: {{ .Values.image.tag | quote }}
- name: BUILD_ID
  value: {{ .Values.build.id | quote }}
- name: GIT_SHA
  value: {{ .Values.build.gitSha | quote }}
- name: POD_NAME
  valueFrom: { fieldRef: { fieldPath: metadata.name } }
- name: NODE_NAME
  valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
{{- end -}}
