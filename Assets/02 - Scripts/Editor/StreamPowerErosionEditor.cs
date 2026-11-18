using UnityEditor;
using UnityEngine;

// Inspector for StreamPowerErosion: the "Erode" button, with Undo.
[CustomEditor(typeof(StreamPowerErosion))]
public class StreamPowerErosionEditor : Editor
{
    public override void OnInspectorGUI()
    {
        DrawDefaultInspector();
        var erosion = (StreamPowerErosion)target;

        EditorGUILayout.Space();
        if (Application.isPlaying)
        {
            EditorGUILayout.HelpBox("Exit Play mode to erode.", MessageType.None);
            return;
        }
        if (GUILayout.Button("Erode", GUILayout.Height(30)))
        {
            TerrainData data = erosion.GetComponent<Terrain>().terrainData;
            Undo.RegisterCompleteObjectUndo(data, "Stream power erosion");
            EditorUtility.DisplayProgressBar("Stream power erosion", $"Running {erosion.iterations} iterations...", 0.5f);
            try
            {
                var timer = System.Diagnostics.Stopwatch.StartNew();
                erosion.Erode();
                Debug.Log($"Stream power erosion: {erosion.iterations} iterations in {timer.Elapsed.TotalSeconds:0.0} s. Ctrl+Z to undo.");
            }
            finally
            {
                EditorUtility.ClearProgressBar();
            }
            EditorUtility.SetDirty(data);
        }
    }
}
