#!/bin/bash
# Global build script variables
SUBCHARTS_PATH="subcharts"
SUBCHART_SCRIPTS_PATH="subchart-scripts"
TEMPLATES_PATH="templates"
MAIN_CHART_PATH="oursystem"
VERSIONS_FILE="versions.yaml"
VALUES_TEMPL_FILE="$TEMPLATES_PATH/values.templ.yaml"
MAIN_CHART_FILE="$MAIN_CHART_PATH/Chart.yaml"
MAIN_VALUES_FILE="$MAIN_CHART_PATH/values.yaml"
VARIABLES_FILE="$TEMPLATES_PATH/variables.yaml"
TMP_PATH="tmp"
SUBCHARTS_TMP_PATH="$TMP_PATH/subcharts"
CONFIG_TMP_FILE="$TMP_PATH/configuration.yaml"
OVERRIDES_TMP_FILE="$TMP_PATH/overrides.yaml"
# Copy all application charts to temporary location
cp -r "$SUBCHARTS_PATH/" "$SUBCHARTS_TMP_PATH"
# Replacing environment tag with the one from CI pipeline
yaml=$(sed "s/%envTag%/$BRANCH_NUM/g" "$VARIABLES_FILE" | yq r - --stripComments)
versions=$(yq r "$VERSIONS_FILE" "versions" --stripComments)
conditions=$(yq r "$VERSIONS_FILE" "conditions" --stripComments)
# Reading common parameter values
env_name=$(echo "$yaml" | yq r - "common.envName")
internal_proto=$(echo "$yaml" | yq r - "common.internalProtocol")
external_proto=$(echo "$yaml" | yq r - "common.externalProtocol")
# Building section for common config
echo "$yaml" | yq p - "global.configuration" > $CONFIG_TMP_FILE
echo "" > $OVERRIDES_TMP_FILE
for key in $(echo "$yaml" | yq r - -p p "*")
do
  # Iterating sections in templates/variables.yaml
  if [[ $key != "common" ]]
  then
    # Copy templates to subcharts
    mkdir -p "$SUBCHARTS_TMP_PATH/$key/templates"
    cp -n templates/subchart/*.yaml "$SUBCHARTS_TMP_PATH/$key/templates"
    # Defining application parameters
    full_name="$env_name-$key"
    version=$(echo "$versions" | yq r - "$key")
    ingress=$(echo "$yaml" | yq r - "$key.host")
    path=$(echo "$yaml" | yq r - "$key.path")
    internal_proto_current=$(echo "$yaml" | yq r - "$key.internalProtocol")
    external_proto_current=$(echo "$yaml" | yq r - "$key.externalProtocol")
    service_name=$(echo "$yaml" | yq r - "$key.serviceName")
    sidecar_name=$(echo "$yaml" | yq r - "$key.sidecar.name")
    if [[ -z "$internal_proto_current" ]]
    then
      internal_proto_current=$internal_proto
    fi
    if [[ -z "$external_proto_current" ]]
    then
      external_proto_current=$external_proto
    fi
    # Writing “derivative” parameters
    if [[ -z "$service_name" ]]
    then
      # Full name for a service
      yq w -i "$CONFIG_TMP_FILE" "global.configuration.$key.service" \ 
        "$full_name"
      # Full URL for a service
      yq w -i "$CONFIG_TMP_FILE" "global.configuration.$key.serviceUrl" \
        "$internal_proto_current://$full_name$path"
    else
      # Full name for a service
      yq w -i "$CONFIG_TMP_FILE" "global.configuration.$key.service" \
        "$env_name-$service_name"
      # Full URL for a service
      yq w -i "$CONFIG_TMP_FILE" "global.configuration.$key.serviceUrl" \
        "$internal_proto_current://$env_name-$service_name$path"
    fi
    if [[ ! -z "$ingress" ]]
    then
      # Full URL for an Ingress
      yq w -i "$CONFIG_TMP_FILE" "global.configuration.$key.ingressUrl" \
        "$external_proto_current://$ingress$path"
    fi
    if [[ ! -z "$version" ]]
    then
      # Current version of application
      yq w -i "$CONFIG_TMP_FILE" "global.configuration.$key.version" \
        "$version"
    fi
    # Redefining application mae
    yq w -i "$OVERRIDES_TMP_FILE" "$key.nameOverride" "$key"
    yq w -i "$OVERRIDES_TMP_FILE" "$key.fullnameOverride" "$full_name"
    # Add an
    ingress_host=$(echo "$yaml" | yq r - "$key.host")
    if [[ ! -z "$ingress_host" ]]
    then
	# Adding definition for an ingress
      sed "s/%ingressHost%/$ingress_host/g" "$INGRESS_TEMPL_FILE" | \
        sed "s/%serviceName%/$full_name/g" - | \
        yq r - --stripComments | yq p - "$key.ingress" | \
        yq m -i "$OVERRIDES_TMP_FILE" -
    else
      # Switching an ingress off
      yq w -i "$OVERRIDES_TMP_FILE" "$key.ingress.enabled" "false"
    fi
    # Writing version to the subchart
    if [[ ! -z "$version" ]]
    then
      subchart="$SUBCHARTS_TMP_PATH/$key/Chart.yaml"
      yq w -i "$subchart" 'appVersion' "${version}"
      yq w -i "$subchart" 'version' "${version}"
    fi
  fi
done
# Defining current version for the system
version=$(yq r ${MAIN_CHART_FILE} "version" --stripComments)
IFS=. read major minor build <<< "${version}"
if [[ -z "${BRANCH_NUM}" ]]
then
  build="${CI_PIPELINE_IID}"
else
  build="${CI_PIPELINE_IID}-env${BRANCH_NUM}"
fi
version="${major}.${minor}.${build}"
# Writing version to the main chart
yq w -i "${MAIN_CHART_FILE}" 'appVersion' "${version}"
yq w -i "${MAIN_CHART_FILE}" 'version' "${version}"
# Building values.yaml for the main chart
yq r "$VALUES_TEMPL_FILE" --stripComments | \
  yq m - "$OVERRIDES_TMP_FILE" "$RESOURCES_FILE" "$CONFIG_TMP_FILE" > $MAIN_VALUES_FILE
# Adding application conditions
echo "$conditions" | yq m -i "$MAIN_VALUES_FILE" -