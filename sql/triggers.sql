-- METI™ DATABASE TRIGGERS

-- Sources table triggers
CREATE TRIGGER trigger_remove_conflict_id
    AFTER DELETE ON public.sources
    FOR EACH ROW
    EXECUTE FUNCTION public.remove_conflict_id_on_delete();

CREATE TRIGGER sources_after_insert_trigger
    AFTER INSERT ON public.sources
    FOR EACH ROW
    EXECUTE FUNCTION public.sources_after_insert();

CREATE TRIGGER sources_before_insert_trigger
    BEFORE INSERT ON public.sources
    FOR EACH ROW
    EXECUTE FUNCTION public.sources_before_insert();

CREATE TRIGGER sources_before_delete_trigger
    BEFORE DELETE ON public.sources
    FOR EACH ROW
    EXECUTE FUNCTION public.sources_before_delete();

CREATE TRIGGER trigger_delete_after_update
    AFTER UPDATE ON public.sources
    FOR EACH ROW
    EXECUTE FUNCTION public.delete_after_update();

CREATE TRIGGER sources_before_update_trigger
    BEFORE UPDATE ON public.sources
    FOR EACH ROW
    WHEN (
        old.geometry IS DISTINCT FROM new.geometry OR
        old.start_at IS DISTINCT FROM new.start_at OR
        old.end_at IS DISTINCT FROM new.end_at
    )
    EXECUTE FUNCTION public.sources_before_update();

-- Sources_queue triggers
CREATE TRIGGER set_created_by_before
    BEFORE INSERT ON public.sources_queue
    FOR EACH ROW
    EXECUTE FUNCTION public.set_created_by();

CREATE TRIGGER process_features_after
    AFTER INSERT ON public.sources_queue
    FOR EACH ROW
    EXECUTE FUNCTION public.process_feature_collection();
