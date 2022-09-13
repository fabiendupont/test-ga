#!/usr/bin/env bash
DEBUG=${DEBUG:-false}

PULL_SECRET_FILE="${PULL_SECRET_FILE:-/pull-secret}"
[ "${DEBUG}" == "true" ] && echo "Getting pull secret from ${PULL_SECRET_FILE}"

MATRIX_FILE="${MATRIX_FILE:-/build-matrix.json}"
[ "${DEBUG}" == "true" ] && echo "Generating matrix in ${MATRIX_FILE}"

# TODO: Use an external matrix for HABANA drivers
HABANA_VERSIONS=("1.6.0-439")

# Retrieve all the unique kernel versions
KVERS=()
for y in $(seq 11 11); do
    for z in $(seq 0 99); do
        for a in "x86_64"; do
            # Get the release image for the z-stream
            [ "${DEBUG}" == "true" ] && echo -n "Get the release image for OCP 4.${y}.${z}-${a}."
            IMG=$(oc adm release info --image-for=machine-os-content quay.io/openshift-release-dev/ocp-release:4.${y}.${z}-${a} 2>/dev/null)

            # If the command failed and arch is x86_64, the z-stream doesn't exist and we can stop the loop.
            # If the command failed and arch is not x86_64, we skip the image lookup.
            if [ $? != 0 ]; then
        	[ "${DEBUG}" == "true" ] && echo " Not found."
        	if [ "${a}" == "x86_64" ]; then
        	    break 2
        	else
        	    continue
        	fi
            fi
            [ "${DEBUG}" == "true" ] && echo " Found."

    	    # Get the image info in JSON format, so we can use jq on it
            IMG_INFO=$(oc image info -o json -a ${PULL_SECRET_FILE} ${IMG} 2>/dev/null)

            # If the command failed, we skip the kernel lookup.
            if [ $? != 0 ]; then
		[ "${DEBUG}" == "true" ] && echo "Image info for OCP 4.${y}.${z}-${a} not available"
		continue
	    fi

            # Add the kernel version from the image labels to the list of kernels
            KVER=( $(echo ${IMG_INFO} | jq -r ".config.config.Labels[\"com.coreos.rpm.kernel\"]") )
            KVERS+=( ${KVER} )
            [ "${DEBUG}" == "true" ] && echo "Kernel version for OCP 4.${y}.${z}-${a} is ${KVER}."
        done
    done
done

# Remove duplicates from the list of kernels and sort it
IFS=" " read -r -a KVERS <<< "$(tr ' ' '\n' <<< "${KVERS[@]}" | sort -u | tr '\n' ' ')"

# Generate a list of unique kernels without arch
IFS=" " read -r -a KVERS_NOARCH <<< "$(tr ' ' '\n' <<< "${KVERS[@]}" | sed "s/\..[^.]*$//" | sort -u | tr '\n' ' ')"

# Initialize the matrix file
echo -n "{ \"versions\": [" > ${MATRIX_FILE}

# Build the matrix from the list of kernel versions
LAST_KVER_NOARCH=""
COUNT=0
for KVER_NOARCH in ${KVERS_NOARCH[@]}; do
    # Extract RHEL version from the kernel version
    RHEL_VERSION=$(echo ${KVER_NOARCH} | rev | cut -d "." -f 1 | rev | sed -e "s/^el//" -e "s/_/./")

    # Retrieve UBI image digest for RHEL version
    UBI_DIGEST=$(oc image info -o json --filter-by-os "linux/amd64" registry.access.redhat.com/ubi8/ubi:${RHEL_VERSION} | jq .digest)

    # Initialize the arch with "x86_64" which is mandatory
    ARCH="linux/amd64"
    ARCH_TAG="x86_64"

    # Generate the matrix entries for the kernel x drivers
    for HL_VER in ${HABANA_VERSIONS[@]}; do
        # Check if a habana-ai-driver image exists for this driver and kernel versions
        BUILD_NEEDED="true"
        DRV_IMG=$(oc image info -a ${PULL_SECRET_FILE} -o json --filter-by-os "linux/amd64" ghcr.io/fabiendupont/habana-ai-driver:${HL_VER}-${KVER_NOARCH}.${ARCH_TAG} 2>/dev/null)
        if [ $? == 0 ]; then
            [ "${DEBUG}" == "true" ] && echo "Habana AI Driver image for ${HL_VER}-${KVER_NOARCH}.${ARCH_TAG} exists. Checking if base image has changed."
            OLD_UBI_DIGEST=$(echo "${DRV_IMG}" | jq -r ".config.config.Labels[\"org.opencontainers.image.base.digest\"]")
            if [ "${OLD_UBI_DIGEST}" == "${CUR_UBI_DIGEST}" ]; then
                [ "${DEBUG}" == "true" ] && echo "The UBI ${RHEL_VERSION} has not changed. No need to build."
                BUILD_NEEDED="false"
            fi
        fi

        if [ "${BUILD_NEEDED}" == "true" ]; then
            # Add a comma for all entries but the first one
            [ ${COUNT} -gt 0 ] && echo -n "," >> ${MATRIX_FILE}

            # Add a line for kernel x driver
            echo -n " { \"rhel\": \"${RHEL_VERSION}\", \"ubi-digest\": ${UBI_DIGEST}, \"kernel\": \"${KVER_NOARCH}\", \"driver\": \"${HL_VER}\", \"arch\": \"${ARCH}\", \"arch_tag\": \"${ARCH_TAG}\" }" >> ${MATRIX_FILE}

            # Increment counter
            ((COUNT++))
	fi
    done
done

# Finalize the matrix file
echo -n " ] }" >> ${MATRIX_FILE}
