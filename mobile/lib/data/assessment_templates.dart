import '../models/student.dart';

const assessmentTemplateVersion = '1.1';

class AssessmentTask {
  const AssessmentTask({
    required this.id,
    required this.cardNumber,
    required this.domain,
    required this.title,
    required this.prompt,
    required this.reference,
    this.isObjective = true,
    this.isReading = false,
    this.instruction = '',
  });
  final String id;
  final int cardNumber;
  final String domain;
  final String title;
  final String prompt;
  final String reference;
  final bool isObjective;
  final bool isReading;
  final String instruction;
}

class AssessmentCard {
  const AssessmentCard({
    required this.number,
    required this.ageGroup,
    required this.title,
    required this.tasks,
  });
  final int number;
  final String ageGroup;
  final String title;
  final List<AssessmentTask> tasks;
}

String? recommendedAgeGroup(StudentRecord student) {
  if (student.ageInMonths >= 6 * 12 && student.ageInMonths < 9 * 12) {
    return '6-8';
  }
  if (student.ageInMonths >= 9 * 12 && student.ageInMonths < 13 * 12) {
    return '9-12';
  }
  return null;
}

/// Content is based on Appendix B of SRS v1.3, not a standardized test.
const assessmentCards = <AssessmentCard>[
  AssessmentCard(
    number: 1,
    ageGroup: '6-8',
    title: 'الوعي الصوتي والقراءة المتدرجة',
    tasks: [
      AssessmentTask(
        id: '1a',
        cardNumber: 1,
        domain: 'القراءة',
        title: 'حذف الصوت الأول',
        prompt: 'قل للطفل: كلمة «سَمَاء»، لو حذفنا حرف «س»، ماذا تصبح؟',
        reference: 'ماء',
      ),
      AssessmentTask(
        id: '1b',
        cardNumber: 1,
        domain: 'القراءة',
        title: 'إبدال الصوت الأول',
        prompt: 'قل للطفل: كلمة «نَامَ»، لو استبدلنا «ن» بحرف «ص»، ماذا تصبح؟',
        reference: 'صام',
      ),
      AssessmentTask(
        id: '1c',
        cardNumber: 1,
        domain: 'القراءة',
        title: 'تجميع الأصوات',
        prompt: 'انطق «قـ - لـ - مـ»، واطلب تجميعها في كلمة واحدة.',
        reference: 'قلم',
      ),
      AssessmentTask(
        id: '1d1',
        cardNumber: 1,
        domain: 'القراءة',
        title: 'قراءة متدرجة — 1',
        prompt: 'اطلب قراءة: دَرَجَ',
        reference: 'دَرَجَ؛ سجّل الحكم المهني ومستوى المساعدة.',
        isReading: true,
      ),
      AssessmentTask(
        id: '1d2',
        cardNumber: 1,
        domain: 'القراءة',
        title: 'قراءة متدرجة — 2',
        prompt: 'اطلب قراءة: بَاب',
        reference: 'بَاب؛ سجّل الحكم المهني ومستوى المساعدة.',
        isReading: true,
      ),
      AssessmentTask(
        id: '1d3',
        cardNumber: 1,
        domain: 'القراءة',
        title: 'قراءة متدرجة — 3',
        prompt: 'اطلب قراءة: شَجَرَة',
        reference: 'شَجَرَة؛ سجّل الحكم المهني ومستوى المساعدة.',
        isReading: true,
      ),
      AssessmentTask(
        id: '1d4',
        cardNumber: 1,
        domain: 'القراءة',
        title: 'قراءة متدرجة — 4',
        prompt: 'اطلب قراءة: مُسْتَشْفَى',
        reference: 'مُسْتَشْفَى؛ سجّل الحكم المهني ومستوى المساعدة.',
        isReading: true,
      ),
    ],
  ),
  AssessmentCard(
    number: 2,
    ageGroup: '6-8',
    title: 'الإملاء والكتابة وملاحظة الأداء',
    tasks: [
      AssessmentTask(
        id: '2a',
        cardNumber: 2,
        domain: 'الكتابة',
        title: 'إملاء جملة',
        prompt: 'أملِ الجملة دون تشكيل: «كَتَبَ أَمِيرٌ الدَّرْسَ فِي الدَّفْتَرِ».',
        reference: 'تتحقق المختصة من الإملاء دون درجة معيارية.',
        isObjective: false,
      ),
      AssessmentTask(
        id: '2b',
        cardNumber: 2,
        domain: 'الكتابة',
        title: 'ملاحظة الكتابة',
        prompt: 'لاحظ مسك القلم واتجاه الكتابة والنقاط والتاء والتنوين أثناء العمل.',
        reference: 'سجل ملاحظات وصفية فقط؛ لا تشخيص من قبضة القلم.',
        isObjective: false,
      ),
    ],
  ),
  AssessmentCard(
    number: 3,
    ageGroup: '6-8',
    title: 'المنطق الرياضي والحل اللفظي',
    tasks: [
      AssessmentTask(
        id: '3a',
        cardNumber: 3,
        domain: 'الرياضيات',
        title: 'العد القفزي',
        prompt: 'أكمل: 2، 4، 6، [ ]، [ ].',
        reference: '8، 10',
      ),
      AssessmentTask(
        id: '3b',
        cardNumber: 3,
        domain: 'الرياضيات',
        title: 'الجمع',
        prompt: '5 + 3 = [ ]',
        reference: '8',
      ),
      AssessmentTask(
        id: '3c',
        cardNumber: 3,
        domain: 'الرياضيات',
        title: 'الطرح',
        prompt: '7 - 2 = [ ]',
        reference: '5',
      ),
      AssessmentTask(
        id: '3d',
        cardNumber: 3,
        domain: 'الرياضيات',
        title: 'مسألة تفاح',
        prompt: 'مع سامي 3 تفاحات، وأعطاه والده تفاحتين. كم أصبحت معه؟',
        reference: '5 تفاحات؛ تُلاحظ طريقة الحل ذهنيًا أو بالرسم.',
      ),
    ],
  ),
  AssessmentCard(
    number: 4,
    ageGroup: '9-12',
    title: 'الطلاقة والفهم القرائي',
    tasks: [
      AssessmentTask(
        id: '4a',
        cardNumber: 4,
        domain: 'القراءة',
        title: 'القراءة الجهرية',
        prompt: '«سَافَرَ أَحْمَدُ مَعَ عَائِلَتِهِ إِلَى المَدِينَةِ بَعْدَ غُرُوبِ الشَّمْسِ، وَكَانَ الطَّقْسُ بَارِداً جِدّاً، فَلَبِسَ مِعْطَفَهُ الثَّقِيلَ.»',
        reference: 'تُسجّل المختصة زمن القراءة والأخطاء والتصحيح الذاتي دون عتبات معيارية.',
        isObjective: false,
        isReading: true,
      ),
      AssessmentTask(
        id: '4b',
        cardNumber: 4,
        domain: 'القراءة',
        title: 'فهم مباشر',
        prompt: 'متى سافر أحمد مع عائلته؟',
        reference: 'بعد غروب الشمس',
      ),
      AssessmentTask(
        id: '4c',
        cardNumber: 4,
        domain: 'القراءة',
        title: 'فهم استنتاجي',
        prompt: 'كيف كان الجو في المدينة؟ وما الدليل من النص؟',
        reference: 'بارد جدًا؛ لأنه ارتدى معطفه الثقيل.',
      ),
      AssessmentTask(
        id: '4d',
        cardNumber: 4,
        domain: 'القراءة',
        title: 'المضاد اللغوي',
        prompt: 'استخرج من النص كلمة ضد كلمة «شُرُوق».',
        reference: 'غروب',
      ),
    ],
  ),
  AssessmentCard(
    number: 5,
    ageGroup: '9-12',
    title: 'الإملاء المتقدم والتعبير',
    tasks: [
      AssessmentTask(
        id: '5a',
        cardNumber: 5,
        domain: 'الكتابة',
        title: 'إملاء متقدم',
        prompt: 'أملِ: «الْقَاضِي الصَّادِقُ يَحْكُمُ بِالْعَدْلِ بَيْنَ النَّاسِ فِي كُلِّ وَقْتٍ».',
        reference: 'تقوّم المختصة كتابة الجملة إملائيًا دون درجات آلية.',
        isObjective: false,
      ),
      AssessmentTask(
        id: '5b',
        cardNumber: 5,
        domain: 'الكتابة',
        title: 'تعبير مكتوب',
        prompt: 'اكتب جملتين أو ثلاثًا عن فصلك المفضل، مع سبب واحد لحبك له.',
        reference: 'تراجع المختصة تكوين الجمل والمعنى ووضوح السبب.',
        isObjective: false,
      ),
    ],
  ),
  AssessmentCard(
    number: 6,
    ageGroup: '9-12',
    title: 'الحساب المركب والكسور',
    tasks: [
      AssessmentTask(
        id: '6a',
        cardNumber: 6,
        domain: 'الرياضيات',
        title: 'الضرب',
        prompt: '7 × 8 = [ ]',
        reference: '56',
      ),
      AssessmentTask(
        id: '6b',
        cardNumber: 6,
        domain: 'الرياضيات',
        title: 'القيمة المنزلية',
        prompt: 'في العدد 354، ما منزلة الرقم 5؟',
        reference: 'العشرات (القيمة 50).',
      ),
      AssessmentTask(
        id: '6c',
        cardNumber: 6,
        domain: 'الرياضيات',
        title: 'الكسور',
        prompt: 'ارسم دائرة إلى أربعة أرباع متساوية، ظلّل ربعًا واسأل عن الكسر المظلل.',
        reference: '1/4',
      ),
      AssessmentTask(
        id: '6d',
        cardNumber: 6,
        domain: 'الرياضيات',
        title: 'مسألة نقود',
        prompt: 'مع رامي 50 دينارًا؛ اشترى كتابًا بـ15 وحقيبة بـ20. كم بقي؟',
        reference: '15 دينارًا',
      ),
    ],
  ),
];

List<AssessmentCard> cardsForAge(String group) =>
    assessmentCards.where((c) => c.ageGroup == group).toList();

List<AssessmentTask> tasksForAge(String group) =>
    cardsForAge(group).expand((card) => card.tasks).toList();
