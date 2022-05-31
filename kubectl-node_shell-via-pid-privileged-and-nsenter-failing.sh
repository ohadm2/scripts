#!/usr/bin/env bash
set -e

kubectl=kubectl
generator=""
node=""
nodefaultctx=0
nodefaultns=0
cmd=(nsenter --target 1 --mount --uts --ipc --net --pid --)
custom=false
if [ -t 0 ]; then
  tty=true
else
  tty=false
fi
while [ $# -gt 0 ]; do
  key="$1"

  case $key in
  --context)
    nodefaultctx=1
    kubectl="$kubectl --context $2"
    shift
    shift
    ;;
  --kubecontext=*)
    nodefaultctx=1
    kubectl="$kubectl --context=${key##*=}"
    shift
    ;;
  --kubeconfig)
    kubectl="$kubectl --kubeconfig $2"
    shift
    shift
    ;;
  --kubeconfig=*)
    kubectl="$kubectl --kubeconfig=${key##*=}"
    shift
    ;;
  -n | --namespace)
    nodefaultns=1
    kubectl="$kubectl --namespace $2"
    shift
    shift
    ;;
  --namespace=*)
    nodefaultns=1
    kubectl="$kubectl --namespace=${key##*=}"
    shift
    ;;
  --)
    shift
    break
    ;;
  *)
    if [ -z "$node" ]; then
      node="$1"
      shift
    else
      echo "exactly one node required"
      exit 1
    fi
    ;;
  esac
done

# Set the default context and namespace to avoid situations where the user switch them during the build process
[ "$nodefaultctx" = 1 ] || kubectl="$kubectl --context=$(${kubectl} config current-context)"
[ "$nodefaultns" = 1 ] || kubectl="$kubectl --namespace=$(${kubectl} config view --minify --output 'jsonpath={.contexts..namespace}')"

if [ $# -gt 0 ]; then
  cmd+=( "${@//
/\\n}" )
else
  cmd+=(bash -l)
fi
# translate embedded single-quotes to double-quotes, so the following line will work
cmd=( "${cmd[@]//\'/\"}" )

# jsonify(as an array) the argument list (mainly from the command line)
entrypoint="$(echo "['${cmd[@]/%/\', \'}']" | sed -e "s/' /'/g" \
                   -e "s/, '']\$/]/" -Ee "s/([\"\\])/\\\\\1/g" -e 's/\\\\n/\\n/g' | tr \' \")"

if [ -z "$node" ]; then
  echo "Please specify node name"
  exit 1
fi

image=repository.local/alpine:3.14.0
pod="nsenter-$(env LC_ALL=C tr -dc a-z0-9 </dev/urandom | head -c 6)"

# Check the node
$kubectl get node "$node" >/dev/null || exit 1

overrides="$(
  cat <<EOT
{
  "spec": {
    "nodeName": "$node",
    "hostPID": true,
    "hostNetwork": true,
    "serviceAccount": "sa-test-ohad",
    "imagePullSecrets": [{"name": "ohad-secret"}],
    "containers": [
      {
        "securityContext": {
          "privileged": true
        },
        "image": "$image",
        "name": "nsenter",
        "stdin": true,
        "stdinOnce": true,
        "tty": $tty,
        "command": $entrypoint
      }
    ],
    "tolerations": [
      {
        "key": "CriticalAddonsOnly",
        "operator": "Exists"
      },
      {
        "effect": "NoExecute",
        "operator": "Exists"
      }
    ]
  }
}
EOT
)"

# Support Kubectl <1.18
m=$(kubectl version --client -o yaml | awk -F'[ :"]+' '$2 == "minor" {print $3+0}')
if [ "$m" -lt 18 ]; then
  generator="--generator=run-pod/v1"
fi

NAMESPACE=test-ohad

trap "EC=\$?; $kubectl -n $NAMESPACE delete pod --wait=false $pod >&2 || true; exit \$EC" EXIT INT TERM

echo "spawning \"$pod\" on \"$node\"" >&2
$kubectl -n $NAMESPACE run --image "$image" --restart=Never --overrides="$overrides"  $([ -t 0 ] && echo -t) -i "$pod" $generator
