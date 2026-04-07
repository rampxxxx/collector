REGISTRY_IP := $(shell kubectl config use-context main-cluster > /dev/null && kubectl get svc -n default main-cluster-internal-registry -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):5000
IMAGE_NAME := golang-api
TAG := latest

deps:
	go mod download

tidy:
	go mod tidy

build: deps
	docker build -t $(IMAGE_NAME):$(TAG) .

push: build
	# Force main cluster context to get correct registry IP
	kubectl config use-context main-cluster > /dev/null
	docker tag $(IMAGE_NAME):$(TAG) $(REGISTRY_IP)/$(IMAGE_NAME):$(TAG)
	docker push $(REGISTRY_IP)/$(IMAGE_NAME):$(TAG)

.PHONY: build push deps tidy
