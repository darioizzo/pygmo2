#!/usr/bin/env bash

# Fail fast on command errors, undefined vars, and pipeline failures.
set -Eeuo pipefail
# Keep shell tracing enabled so CI logs show every step and argument.
set -x

# Required inputs from the workflow/container invocation.
: "${PYGMO_BUILD_TYPE:?PYGMO_BUILD_TYPE is required}"
: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"

# Basic context useful for debugging CI runs.
echo "PYGMO_BUILD_TYPE: ${PYGMO_BUILD_TYPE}"
echo "GITHUB_REF: ${GITHUB_REF:-<unset>}"
echo "GITHUB_WORKSPACE: ${GITHUB_WORKSPACE}"

# Preflight: list interpreters baked into the manylinux image.
# This makes Python-version mismatches obvious in the logs.
echo "Preflight: available Python installs under /opt/python"
if [[ -d /opt/python ]]; then
	ls -1 /opt/python || true
else
	echo "WARNING: /opt/python directory is missing"
fi

for expected_dir in cp311-cp311 cp312-cp312 cp313-cp313 cp314-cp314; do
	if [[ -x "/opt/python/${expected_dir}/bin/python" ]]; then
		echo "Found interpreter: /opt/python/${expected_dir}/bin/python"
	else
		echo "Missing interpreter: /opt/python/${expected_dir}/bin/python"
	fi
done

# Needed when running in GitHub Actions containers.
git config --global --add safe.directory "${GITHUB_WORKSPACE}"

# Map workflow build type to the manylinux Python ABI directory.
case "${PYGMO_BUILD_TYPE}" in
	*314*) PYTHON_DIR="cp314-cp314" ;;
	*313*) PYTHON_DIR="cp313-cp313" ;;
	*312*) PYTHON_DIR="cp312-cp312" ;;
	*311*) PYTHON_DIR="cp311-cp311" ;;
	*)
		echo "Invalid build type '${PYGMO_BUILD_TYPE}'. Supported: Python314, Python313, Python312, Python311"
		exit 1
		;;
esac

# Resolve python/pip/ipcluster binaries for the selected interpreter.
PYBIN="/opt/python/${PYTHON_DIR}/bin"
if [[ ! -x "${PYBIN}/python" ]]; then
	echo "Python executable not found at ${PYBIN}/python. Update the manylinux image for ${PYTHON_DIR}."
	exit 1
fi
echo "PYTHON_DIR: ${PYTHON_DIR}"

# The pagmo release tag can be overridden from the workflow if needed.
PAGMO_VERSION_RELEASE="${PAGMO_VERSION_RELEASE:-2.19.1}"

export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1

echo "OMP_NUM_THREADS: ${OMP_NUM_THREADS}"
echo "OPENBLAS_NUM_THREADS: ${OPENBLAS_NUM_THREADS}"

# Tag builds publish wheels; non-tag builds only build/test.
if [[ "${GITHUB_REF:-}" == "refs/tags/v"* ]]; then
	echo "Tag build detected"
	PYGMO_RELEASE_BUILD="yes"
else
	echo "Non-tag build detected"
	PYGMO_RELEASE_BUILD="no"
fi

# Install packaging/build/test runtime dependencies in the selected Python.
"${PYBIN}/python" -m pip install --upgrade pip setuptools wheel
"${PYBIN}/python" -m pip install cloudpickle numpy
"${PYBIN}/python" -m pip install networkx ipyparallel scipy auditwheel twine

# Build and install pagmo2 (released tarball on tags, git HEAD otherwise).
cd /root/install
if [[ "${PYGMO_RELEASE_BUILD}" == "yes" ]]; then
	curl -fsSL -o pagmo2.tar.gz "https://github.com/esa/pagmo2/archive/refs/tags/v${PAGMO_VERSION_RELEASE}.tar.gz"
	tar xzf pagmo2.tar.gz
	cd "pagmo2-${PAGMO_VERSION_RELEASE}"
else
	rm -rf pagmo2
	git clone --depth 1 https://github.com/esa/pagmo2.git
	cd pagmo2
fi

# Configure and install pagmo2 into the container's default prefix.
rm -rf build
mkdir -p build
cd build
cmake -DBoost_NO_BOOST_CMAKE=ON \
	-DPAGMO_WITH_EIGEN3=yes \
	-DPAGMO_WITH_NLOPT=yes \
	-DPAGMO_WITH_IPOPT=yes \
	-DPAGMO_ENABLE_IPO=OFF \
	-DCMAKE_BUILD_TYPE=Release ../
cmake --build . --target install --parallel 1

# Configure and install pygmo against the selected Python interpreter.
cd "${GITHUB_WORKSPACE}"
rm -rf build
mkdir -p build
cd build
cmake -DBoost_NO_BOOST_CMAKE=ON \
	-DCMAKE_BUILD_TYPE=Release \
	-DPYGMO_ENABLE_IPO=OFF \
	-DPython3_EXECUTABLE="${PYBIN}/python" ../
cmake --build . --target install --parallel 1

# Build wheel from the wheel/ packaging directory and repair it for manylinux.
cd wheel
rm -rf pygmo
cp -r ../pygmo ./

"${PYBIN}/python" setup.py bdist_wheel
auditwheel repair dist/pygmo*.whl -w ./dist2

# Smoke-test the repaired wheel in a clean root context.
cd /
"${PYBIN}/python" -m pip install --force-reinstall "${GITHUB_WORKSPACE}/build/wheel/dist2/pygmo"*.whl
"${PYBIN}/ipcluster" start --daemonize=True -n 1
sleep 20
"${PYBIN}/python" -c "import pygmo; pygmo.test.run_test_suite(1); pygmo.mp_island.shutdown_pool(); pygmo.mp_bfe.shutdown_pool()"

# Upload wheels only for version tags.
if [[ "${PYGMO_RELEASE_BUILD}" == "yes" ]]; then
	"${PYBIN}/python" -m twine upload --non-interactive --skip-existing "${GITHUB_WORKSPACE}/build/wheel/dist2/pygmo"*.whl
fi

set +x
