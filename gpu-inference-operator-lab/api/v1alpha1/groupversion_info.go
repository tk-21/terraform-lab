// Package v1alpha1 contains API Schema definitions for the inference v1alpha1 API group
// +kubebuilder:object:generate=true
// +groupName=inference.takuya.dev
package v1alpha1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	// GroupVersion は inference.takuya.dev/v1alpha1 グループ・バージョン
	GroupVersion = schema.GroupVersion{Group: "inference.takuya.dev", Version: "v1alpha1"}

	// SchemeBuilder はGroupVersionにGoの型を登録するためのビルダー
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

	// AddToScheme はスキームにこのグループのバージョンを追加する関数
	AddToScheme = SchemeBuilder.AddToScheme
)
