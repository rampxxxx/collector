REGISTRY_IP := $(shell kubectl config use-context main-cluster 1>/dev/null; kubectl get svc -n default main-cluster-internal-registry -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):5000
IMAGE_NAME := rust-collector
TAG := latest

build:
	docker build -t $(IMAGE_NAME):$(TAG) .

push: build
	docker tag $(IMAGE_NAME):$(TAG) $(REGISTRY_IP)/$(IMAGE_NAME):$(TAG)
	docker push $(REGISTRY_IP)/$(IMAGE_NAME):$(TAG)

.PHONY: build push
