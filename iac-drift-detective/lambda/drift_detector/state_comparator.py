"""
ステートコンパレーター / Terraform stateとCloudFormationドリフト結果を突き合わせて
差分リストを生成するモジュール
"""


def compare_states(tf_resources: dict, cfn_drifts: list) -> list:
    """
    tfstateのリソースとCloudFormationドリフト結果を突き合わせて差分リストを返す。

    Args:
        tf_resources: get_terraform_resources()の戻り値
        cfn_drifts: get_cloudformation_drifts()の戻り値

    Returns:
        ドリフト差分情報のリスト
    """
    results = []

    for drift in cfn_drifts:
        physical_id = drift.get("physical_id", "")

        # physical_idでtf_resourcesと照合する
        resource_address = f"unknown/{physical_id}"
        for addr, res_info in tf_resources.items():
            # attributesの値の中にphysical_idと一致するものがあるか確認
            attributes = res_info.get("attributes", {})
            if physical_id in attributes.values():
                resource_address = addr
                break

        # drift_statusに応じてdrift_typeを決定
        drift_status = drift.get("drift_status", "")
        if drift_status == "DELETED":
            drift_type = "RESOURCE_DELETED"
        else:
            drift_type = "PROPERTY_CHANGE"

        # expected_propertiesとactual_propertiesのキーをunionして差分を抽出
        expected = drift.get("expected_properties", {})
        actual = drift.get("actual_properties", {})
        all_keys = set(expected.keys()) | set(actual.keys())

        changed_properties = []
        for prop_key in all_keys:
            expected_val = expected.get(prop_key)
            actual_val = actual.get(prop_key)
            # 値が異なる場合のみ差分として記録
            if expected_val \!= actual_val:
                changed_properties.append(
                    {
                        "property_path": prop_key,
                        "expected_value": expected_val,
                        "actual_value": actual_val,
                    }
                )

        # ドリフト情報を組み立てる
        drift_entry = {
            "resource_address": resource_address,
            "resource_type": drift.get("resource_type", ""),
            "physical_id": physical_id,
            "drift_type": drift_type,
            "changed_properties": changed_properties,
            "severity": "",  # calculate_severityで後から設定
        }
        # severityを算出してセット
        drift_entry["severity"] = calculate_severity(drift_entry)

        results.append(drift_entry)

    return results


def calculate_severity(drift: dict) -> str:
    """
    ドリフトのseverityを算出する。
    changed_propertiesのproperty_pathを見てHIGH/MEDIUM/LOWを判定し、
    複数プロパティがある場合は最も高いseverityを返す。

    Args:
        drift: compare_states()で生成するdrift_entryのdict

    Returns:
        "HIGH" / "MEDIUM" / "LOW" のいずれか
    """
    # severityの優先度マッピング（数値が大きいほど高い）
    severity_rank = {"HIGH": 2, "MEDIUM": 1, "LOW": 0}

    # HIGH判定対象のキーワード
    high_keywords = [
        "SecurityGroup",
        "IamInstanceProfile",
        "KmsKeyId",
        "Encrypted",
        "SslPolicy",
    ]
    # MEDIUM判定対象のキーワード
    medium_keywords = [
        "InstanceType",
        "VolumeSize",
        "AllocatedStorage",
        "MultiAZ",
    ]

    current_rank = 0  # デフォルトはLOW

    for prop in drift.get("changed_properties", []):
        path = prop.get("property_path", "")

        # HIGHキーワードが含まれるか確認
        if any(kw in path for kw in high_keywords):
            prop_severity = "HIGH"
        # MEDIUMキーワードが含まれるか確認
        elif any(kw in path for kw in medium_keywords):
            prop_severity = "MEDIUM"
        else:
            prop_severity = "LOW"

        # より高いseverityで更新する
        if severity_rank[prop_severity] > current_rank:
            current_rank = severity_rank[prop_severity]

    # ランクをseverity文字列に変換して返す
    rank_to_severity = {2: "HIGH", 1: "MEDIUM", 0: "LOW"}
    return rank_to_severity[current_rank]
