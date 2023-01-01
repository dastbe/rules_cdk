"""WORKSPACE level dependencies"""

load("@bazel_gazelle//:deps.bzl", "go_repository")

def go_dependencies():
    """Initialize all go_repository targets for this WORKSPACE"""
    go_repository(
        name = "com_github_aws_aws_cdk_go_awscdk_v2",
        build_external = "external",
        importpath = "github.com/aws/aws-cdk-go/awscdk/v2",
        sum = "h1:3gi34Y7Z8zmvcxUYnRcQrh2doW/RsXAsy+V1JD1ej7I=",
        version = "v2.58.1",
    )
    go_repository(
        name = "com_github_aws_constructs_go_constructs_v10",
        build_external = "external",
        importpath = "github.com/aws/constructs-go/constructs/v10",
        sum = "h1:PmI42w6gXXcXBMZgx6KO0ndHb5xGyUcndV39/nPzxMU=",
        version = "v10.1.189",
    )
    go_repository(
        name = "com_github_aws_jsii_runtime_go",
        build_external = "external",
        importpath = "github.com/aws/jsii-runtime-go",
        sum = "h1:5jMBCUu/qINj0hSt08gkyVyKRbrRBb9RV8ETGxTb+lo=",
        version = "v1.72.0",
    )
    go_repository(
        name = "com_github_cdklabs_awscdk_asset_awscli_go_awscliv1_v2",
        build_external = "external",
        importpath = "github.com/cdklabs/awscdk-asset-awscli-go/awscliv1/v2",
        sum = "h1:ryT4dP31QvXF7SO3mij6ir+8JBRaHyv1NSd2seUgpH4=",
        version = "v2.2.30",
    )
    go_repository(
        name = "com_github_cdklabs_awscdk_asset_kubectl_go_kubectlv20_v2",
        build_external = "external",
        importpath = "github.com/cdklabs/awscdk-asset-kubectl-go/kubectlv20/v2",
        sum = "h1:l5N27aCCjAB5cgW5pI4/ujnasPL8hUcJ9KBxrKk6UiQ=",
        version = "v2.1.1",
    )
    go_repository(
        name = "com_github_cdklabs_awscdk_asset_node_proxy_agent_go_nodeproxyagentv5_v2",
        build_external = "external",
        importpath = "github.com/cdklabs/awscdk-asset-node-proxy-agent-go/nodeproxyagentv5/v2",
        sum = "h1:IgRq7F3odfHx5cnb+ejlMV+jGTmNOH7pJnSt8ownfvc=",
        version = "v2.0.38",
    )
    go_repository(
        name = "com_github_davecgh_go_spew",
        build_external = "external",
        importpath = "github.com/davecgh/go-spew",
        sum = "h1:vj9j/u1bqnvCEfJOwUhtlOARqs3+rkHYY13jYWTU97c=",
        version = "v1.1.1",
    )
    go_repository(
        name = "com_github_masterminds_semver_v3",
        build_external = "external",
        importpath = "github.com/Masterminds/semver/v3",
        sum = "h1:3MEsd0SM6jqZojhjLWWeBY+Kcjy9i6MQAeY7YgDP83g=",
        version = "v3.2.0",
    )
    go_repository(
        name = "com_github_mattn_go_isatty",
        build_external = "external",
        importpath = "github.com/mattn/go-isatty",
        sum = "h1:bq3VjFmv/sOjHtdEhmkEV4x1AJtvUvOJ2PFAZ5+peKQ=",
        version = "v0.0.16",
    )
    go_repository(
        name = "com_github_pmezard_go_difflib",
        build_external = "external",
        importpath = "github.com/pmezard/go-difflib",
        sum = "h1:4DBwDE0NGyQoBHbLQYPwSUPoCMWR5BEzIk/f1lZbAQM=",
        version = "v1.0.0",
    )
    go_repository(
        name = "com_github_stretchr_testify",
        build_external = "external",
        importpath = "github.com/stretchr/testify",
        sum = "h1:w7B6lhMri9wdJUVmEZPGGhZzrYTPvgJArz7wNPgYKsk=",
        version = "v1.8.1",
    )
    go_repository(
        name = "com_github_yuin_goldmark",
        build_external = "external",
        importpath = "github.com/yuin/goldmark",
        sum = "h1:fVcFKWvrslecOb/tg+Cc05dkeYx540o0FuFt3nUVDoE=",
        version = "v1.4.13",
    )
    go_repository(
        name = "in_gopkg_yaml_v3",
        build_external = "external",
        importpath = "gopkg.in/yaml.v3",
        sum = "h1:fxVm/GzAzEWqLHuvctI91KS9hhNmmWOoWu0XTYJS7CA=",
        version = "v3.0.1",
    )
    go_repository(
        name = "org_golang_x_lint",
        build_external = "external",
        importpath = "golang.org/x/lint",
        sum = "h1:VLliZ0d+/avPrXXH+OakdXhpJuEoBZuwh1m2j7U6Iug=",
        version = "v0.0.0-20210508222113-6edffad5e616",
    )
    go_repository(
        name = "org_golang_x_mod",
        build_external = "external",
        importpath = "golang.org/x/mod",
        sum = "h1:LapD9S96VoQRhi/GrNTqeBJFrUjs5UHCAtTlgwA5oZA=",
        version = "v0.7.0",
    )
    go_repository(
        name = "org_golang_x_sys",
        build_external = "external",
        importpath = "golang.org/x/sys",
        sum = "h1:ljd4t30dBnAvMZaQCevtY0xLLD0A+bRZXbgLMLU1F/A=",
        version = "v0.2.0",
    )
    go_repository(
        name = "org_golang_x_tools",
        build_external = "external",
        importpath = "golang.org/x/tools",
        sum = "h1:SrNbZl6ECOS1qFzgTdQfWXZM9XBkiA6tkFrH9YSTPHM=",
        version = "v0.3.0",
    )
