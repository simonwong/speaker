import SpeakerSpecSupport

@main
struct SpeakerCoreSpecs {
    @MainActor
    static func main() async {
        var failures: [String] = []

        await AudioStreamSpecs.run(failures: &failures)
        await InputTargetSpecs.run(failures: &failures)
        await ShortcutSpecs.run(failures: &failures)
        await AudioCaptureSpecs.run(failures: &failures)
        await VoiceInputSessionSpecs.run(failures: &failures)
        await RecordingLimitSpecs.run(failures: &failures)
        await SessionCancellationSpecs.run(failures: &failures)
        await DoubaoClientSpecs.run(failures: &failures)
        await DeepSeekRefinementSpecs.run(failures: &failures)
        await CredentialStoreSpecs.run(failures: &failures)
        await SessionHistorySpecs.run(failures: &failures)
        await PersonalDictionarySpecs.run(failures: &failures)
        await OwnerOnlyPersistenceSpecs.run(failures: &failures)
        await AppSettingsStoreSpecs.run(failures: &failures)
        await UsageStatisticsSpecs.run(failures: &failures)

        SpecSummary.finish(failures: failures, label: "core specs")
    }
}
