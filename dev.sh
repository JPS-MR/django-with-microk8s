#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

main() {
  case $1 in
    start)
      start
      ;;
    stop)
      stop
      ;;
    restart)
      stop
      start
      status
      ;;
    status)
      status
      ;;
    postgres-logs)
      postgres_logs
      ;;
    server-logs)
      server_logs
      ;;
    startup-logs)
      startup_logs
      ;;
    test)
      run_tests
      ;;
    manage)
      run_manage "$@"
      ;;
    server-shell)
      server_shell
      ;;
    *)
      echo "Unknown command"
      exit 1
      ;;
  esac
}

start() {
  echo "Build image"
  docker build -t server:development-server -f deploy/docker/development-server/Dockerfile .

  echo "Pushing image to registry"
  docker tag server:development-server localhost:32000/server:development-server
  docker push localhost:32000/server:development-server

  echo "Setting up Secrets"
  microk8s.helm3 install development-secrets deploy/helm/development-secrets/ \
               -n development --create-namespace

  echo "Installing database"
  microk8s.helm3 install development-db deploy/helm/development-db/ \
               -n development --create-namespace

  echo "Wait for database to be ready"
  # We need to wait, because the server chart assumes a db is available for it and will try to run a migration job.
  # Helm has a bug that prevents us from using the --wait flag on the database install command, so we'll use kubectl.
  microk8s.kubectl -n development wait --for=condition=ready pod -l app=postgres

  echo "Installing server"
  microk8s.helm3 install development-app deploy/helm/development-app/ \
               -n development --create-namespace \
               --set projectDir="${PROJECT_ROOT}/server" \
               --set imagePullPolicy=Always \
               --set imageTag="localhost:32000/server:development-server" \

  echo "Configuring Ingress"
  microk8s.kubectl apply -f deploy/helm/development-app/microk8s-ingress.yaml
}

stop() {
  microk8s.helm3 -n development uninstall development-secrets development-db development-app
}

status() {
  microk8s.kubectl -n development get pods
}

postgres_logs() {
  microk8s.kubectl -n development logs -l app=postgres -f --tail 100
}

server_logs() {
  microk8s.kubectl -n development logs -l tier=server -f --tail 100
}

startup_logs() {
  microk8s.kubectl -n development logs -l tier=startup -f --tail 100
}

server_pod() {
  local name=$(kubectl -n development get pods --selector=tier=server  --no-headers -o custom-columns=":metadata.name")
  echo "$name"
}

server_shell() {
  microk8s.kubectl -n development exec -it $(server_pod) -- /bin/sh
}

run_tests() {
  microk8s.kubectl -n development exec $(server_pod) -- python manage.py test
}

run_manage() {
  shift
  microk8s.kubectl -n development exec $(server_pod) -- python manage.py "$@"
}

main "$@"